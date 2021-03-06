//===-------------- ClangVersionedDependencyResolution.swift --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import TSCBasic

/// A map from a module identifier to a set of module dependency graphs
/// Used to compute distinct graphs corresponding to different target versions for a given clang module
public typealias ModuleVersionedGraphMap = [ModuleDependencyId: [InterModuleDependencyGraph]]

internal extension Driver {
  // Dependency scanning results may vary depending on the target version specified on the
  // dependency scanning action. If the scanning action is performed at a fixed target, and the
  // scanned module is later compiled with a higher version target, miscomputation may occur
  // due to dependencies present only at the higher version number and thus not detected by
  // the dependency scanner. We must ensure to re-scan Clang modules at all targets at which
  // they will be compiled and record a super-set of the module's dependencies at all targets.
  /// For each clang module, compute its dependencies at all targets at which it will be compiled.
  mutating func resolveVersionedClangDependencies(dependencyGraph: inout InterModuleDependencyGraph)
  throws {
    // Traverse the dependency graph, collecting extraPCMArgs along each path
    // to all Clang modules, and compute a set of distinct PCMArgs across all paths to a
    // given Clang module in the graph.
    let modulePCMArgsSetMap = try dependencyGraph.computePCMArgSetsForClangModules()

    // Set up the batch scan input
    let temporaryDirectory = try determineTempDirectory()
    let batchScanInputList =
      try modulePCMArgsSetMap.compactMap { (moduleId, pcmArgsSet) throws -> [BatchScanModuleInfo] in
        var moduleInfos: [BatchScanModuleInfo] = []
        for pcmArgs in pcmArgsSet {
          var hasher = Hasher()
          pcmArgs.forEach { hasher.combine($0) }
          // Generate a filepath for the output dependency graph
          let moduleDependencyGraphPath =
            temporaryDirectory.appending(component: moduleId.moduleName +
                                          String(hasher.finalize()) +
                                          "-dependencies.json")
          let moduleBatchInfo =
            BatchScanModuleInfo.clang(
              BatchScanClangModuleInfo(moduleName: moduleId.moduleName,
                                       pcmArgs: pcmArgs.joined(separator: " "),
                                       outputPath: moduleDependencyGraphPath.description))
          moduleInfos.append(moduleBatchInfo)
        }
        return moduleInfos
      }.reduce([], +)

    // Batch scan all clang modules for each discovered new, unique set of PCMArgs, per module
    let moduleVersionedGraphMap: [ModuleDependencyId: [InterModuleDependencyGraph]] =
      try performBatchDependencyScan(moduleInfos: batchScanInputList)

    // Update the dependency graph to reflect the newly-discovered dependencies
    try dependencyGraph.resolveVersionedClangModules(using: moduleVersionedGraphMap)
    try dependencyGraph.updateCapturedPCMArgClangDependencies(using: modulePCMArgsSetMap)
  }
}

private extension InterModuleDependencyGraph {
  /// For each module scanned at multiple target versions, combine their dependencies across version-specific graphs.
  mutating func resolveVersionedClangModules(using versionedGraphMap: ModuleVersionedGraphMap)
  throws {
    // Process each re-scanned module and its collection of graphs
    for (moduleId, graphList) in versionedGraphMap {
      for versionedGraph in graphList {
        // We must update dependencies for each module in the versioned graph, not just
        // the top-level re-scanned module itself.
        for rescannedModuleId in versionedGraph.modules.keys {
          guard let versionedModuleInfo = versionedGraph.modules[rescannedModuleId] else {
            throw Driver.Error.missingModuleDependency(moduleId.moduleName)
          }
          // If the main graph already contains this module, update its dependencies
          if var currentModuleInfo = modules[rescannedModuleId] {
            versionedModuleInfo.directDependencies?.forEach { dependencyId in
              // If a not-seen-before dependency has been found, add it to the info
              if !currentModuleInfo.directDependencies!.contains(dependencyId) {
                currentModuleInfo.directDependencies!.append(dependencyId)
              }
            }
            // Update the moduleInfo with the one whose dependencies consist of a super-set
            // of dependencies across all of the versioned dependency graphs
            modules[rescannedModuleId] = currentModuleInfo
          } else {
            // If the main graph does not yet contain this module, add it to the graph
            modules[rescannedModuleId] = versionedModuleInfo
          }
        }
      }
    }
  }

  /// DFS from the main module to all clang modules, accumulating distinct
  /// PCMArgs along all paths to a given Clang module
  func computePCMArgSetsForClangModules() throws -> [ModuleDependencyId : Set<[String]>] {
    let mainModuleId: ModuleDependencyId = .swift(mainModuleName)
    var pcmArgSetMap: [ModuleDependencyId : Set<[String]>] = [:]

    func visit(_ moduleId: ModuleDependencyId,
               pathPCMArtSet: Set<[String]>,
               pcmArgSetMap: inout [ModuleDependencyId : Set<[String]>])
    throws {
      switch moduleId {
        case .swift:
          // Add extraPCMArgs of the visited node to the current path set
          // and proceed to visit all direct dependencies
          let modulePCMArgs = try swiftModulePCMArgs(of: moduleId)
          var newPathPCMArgSet = pathPCMArtSet
          newPathPCMArgSet.insert(modulePCMArgs)
          for dependencyId in try moduleInfo(of: moduleId).directDependencies! {
            try visit(dependencyId,
                      pathPCMArtSet: newPathPCMArgSet,
                      pcmArgSetMap: &pcmArgSetMap)
          }
        case .clang:
          // The details of this module contain information on which sets of PCMArgs are already
          // captured in the described dependencies of this module. Only re-scan at PCMArgs not
          // already captured.
          let moduleDetails = try clangModuleDetails(of: moduleId)
          let alreadyCapturedPCMArgs = moduleDetails.dependenciesCapturedPCMArgs ?? Set<[String]>()
          let newPCMArgSet = pathPCMArtSet.filter { !alreadyCapturedPCMArgs.contains($0) }
          // Add current path's PCMArgs to the SetMap and stop traversal
          if pcmArgSetMap[moduleId] != nil {
            newPCMArgSet.forEach { pcmArgSetMap[moduleId]!.insert($0) }
          } else {
            pcmArgSetMap[moduleId] = newPCMArgSet
          }
          return
        case .swiftPrebuiltExternal:
          // We can rely on the fact that this pre-built module already has its
          // versioned-PCM dependencies satisfied, so we do not need to add additional
          // arguments. Proceed traversal to its dependencies.
          for dependencyId in try moduleInfo(of: moduleId).directDependencies! {
            try visit(dependencyId,
                      pathPCMArtSet: pathPCMArtSet,
                      pcmArgSetMap: &pcmArgSetMap)
          }
        case .swiftPlaceholder:
          fatalError("Unresolved placeholder dependencies at planning stage: \(moduleId)")
      }
    }

    try visit(mainModuleId,
              pathPCMArtSet: [],
              pcmArgSetMap: &pcmArgSetMap)
    return pcmArgSetMap
  }

  /// Update the set of all PCMArgs against which a given clang module was re-scanned
  mutating func updateCapturedPCMArgClangDependencies(using pcmArgSetMap:
                                                        [ModuleDependencyId : Set<[String]>]
  ) throws {
    for (moduleId, newPCMArgs) in pcmArgSetMap {
      var moduleDetails = try clangModuleDetails(of: moduleId)
      if moduleDetails.dependenciesCapturedPCMArgs == nil {
        moduleDetails.dependenciesCapturedPCMArgs = Set<[String]>()
      }
      newPCMArgs.forEach { moduleDetails.dependenciesCapturedPCMArgs!.insert($0) }
      modules[moduleId]!.details = .clang(moduleDetails)
    }
  }
}

public extension InterModuleDependencyGraph {
  /// Given two moduleInfos of clang modules, merge them by combining their directDependencies and
  /// dependenciesCapturedPCMArgs and sourceFiles fields. These fields may differ across the same module
  /// scanned at different PCMArgs (e.g. -target option).
  static func mergeClangModuleInfoDependencies(_ firstInfo: ModuleInfo, _ secondInfo:ModuleInfo
  ) -> ModuleInfo {
    guard case .clang(let firstDetails) = firstInfo.details,
          case .clang(let secondDetails) = secondInfo.details
    else {
      fatalError("mergeClangModules expected two valid ClangModuleDetails objects.")
    }

    // As far as their dependencies go, these module infos are identical
    if firstInfo.directDependencies == secondInfo.directDependencies,
       firstDetails.dependenciesCapturedPCMArgs == secondDetails.dependenciesCapturedPCMArgs,
       firstInfo.sourceFiles == secondInfo.sourceFiles {
      return firstInfo
    }

    // Create a new moduleInfo that represents this module with combined dependency information
    let firstModuleSources = firstInfo.sourceFiles ?? []
    let secondModuleSources = secondInfo.sourceFiles ?? []
    let combinedSourceFiles = Array(Set(firstModuleSources + secondModuleSources))

    let firstModuleDependencies = firstInfo.directDependencies ?? []
    let secondModuleDependencies = secondInfo.directDependencies ?? []
    let combinedDependencies = Array(Set(firstModuleDependencies + secondModuleDependencies))

    let firstModuleCapturedPCMArgs = firstDetails.dependenciesCapturedPCMArgs ?? Set<[String]>()
    let secondModuleCapturedPCMArgs = secondDetails.dependenciesCapturedPCMArgs ?? Set<[String]>()
    let combinedCapturedPCMArgs = firstModuleCapturedPCMArgs.union(secondModuleCapturedPCMArgs)

    let combinedModuleDetails =
      ClangModuleDetails(moduleMapPath: firstDetails.moduleMapPath,
                         dependenciesCapturedPCMArgs: combinedCapturedPCMArgs,
                         contextHash: firstDetails.contextHash,
                         commandLine: firstDetails.commandLine)

    return ModuleInfo(modulePath: firstInfo.modulePath,
                      sourceFiles: combinedSourceFiles,
                      directDependencies: combinedDependencies,
                      details: .clang(combinedModuleDetails))
  }
}
