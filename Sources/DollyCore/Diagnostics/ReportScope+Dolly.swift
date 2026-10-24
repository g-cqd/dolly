public import ProjectModel
import SourceCorpus

extension ReportScope {
  /// A scope over `files`, canonicalized the way dolly canonicalizes findings' paths.
  public init(files: some Sequence<String>) {
    self.init(files: files, canonicalize: SourcePath.canonical)
  }
}
