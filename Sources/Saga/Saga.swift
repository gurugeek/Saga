import Foundation
import PathKit

public class Saga<SiteMetadata: Metadata> {
  public let rootPath: Path
  public let inputPath: Path
  public let outputPath: Path
  public let siteMetadata: SiteMetadata

  public let fileStorage: [FileContainer]
  internal var processSteps = [AnyProcessStep]()
  internal let fileIO: FileIO

  public init(input: Path, output: Path = "deploy", siteMetadata: SiteMetadata, fileIO: FileIO = .diskAccess, originFilePath: StaticString = #file) throws {
    let originFile = Path("\(originFilePath)")
    rootPath = try fileIO.resolveSwiftPackageFolder(originFile)
    inputPath = rootPath + input
    outputPath = rootPath + output
    self.siteMetadata = siteMetadata
    self.fileIO = fileIO

    // 1. Find all files in the source folder
    let files = try fileIO.findFiles(inputPath)

    // 2. Turn the files into FileContainers so we can keep track if they're handled or not
    self.fileStorage = files.map { path in
      FileContainer(
        path: path
      )
    }
  }

  @discardableResult
  public func register<M: Metadata>(folder: Path? = nil, metadata: M.Type, readers: [Reader<M>], itemWriteMode: ItemWriteMode = .moveToSubfolder, filter: @escaping ((Item<M>) -> Bool) = { _ in true }, writers: [Writer<M, SiteMetadata>]) throws -> Self {
    let step = ProcessStep(folder: folder, readers: readers, filter: filter, writers: writers)
    self.processSteps.append(
      .init(
        step: step,
        fileStorage: fileStorage,
        inputPath: inputPath,
        outputPath: outputPath,
        itemWriteMode: itemWriteMode,
        siteMetadata: siteMetadata,
        fileIO: fileIO
      ))
    return self
  }

  @discardableResult
  public func run() async throws -> Self {
    print("\(Date()) | Starting run")

    // Run all the readers for all the steps, which turns raw content into
    // Items, and stores them within the step.
    let readStart = DispatchTime.now()
    for step in processSteps {
      try await step.runReaders()
    }

    let readEnd = DispatchTime.now()
    let readTime = readEnd.uptimeNanoseconds - readStart.uptimeNanoseconds
    print("\(Date()) | Finished readers in \(Double(readTime) / 1_000_000_000)s")

    // Clean the output folder
    try fileIO.deletePath(outputPath)

    // And run all the writers for all the steps, using those stored Items.
    let writeStart = DispatchTime.now()
    for step in processSteps {
      try step.runWriters()
    }

    let writeEnd = DispatchTime.now()
    let writeTime = writeEnd.uptimeNanoseconds - writeStart.uptimeNanoseconds
    print("\(Date()) | Finished writers \(Double(writeTime) / 1_000_000_000)s")

    return self
  }

  // Copies all unhandled files as-is to the output folder.
  @discardableResult
  public func staticFiles() throws -> Self {
    let start = DispatchTime.now()

    let unhandledPaths = fileStorage
      .filter { $0.handled == false }
      .map(\.path)

    for path in unhandledPaths {
      let relativePath = try path.relativePath(from: inputPath)
      let input = path
      let output = outputPath + relativePath
      try fileIO.mkpath(output.parent())
      try fileIO.copy(input, output)
    }

    let end = DispatchTime.now()
    let time = end.uptimeNanoseconds - start.uptimeNanoseconds
    print("\(Date()) | Finished copying static files in \(Double(time) / 1_000_000_000)s")

    return self
  }
}
