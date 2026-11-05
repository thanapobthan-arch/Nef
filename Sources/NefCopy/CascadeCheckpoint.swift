import Foundation

struct CascadeCheckpoint:Codable {
    struct File:Codable {
        let relativePath:String
        let size:Int64
        let checksum:String
    }
    let version:Int
    let primary:URL
    let primaryVolume:VolumeIdentity
    let originalSources:[URL]
    let destinations:[URL]
    let files:[File]
    let primaryReport:URL?

    func validate(sources:[URL],destinations:[URL],primary:URL?)throws {
        func paths(_ urls:[URL])->[String] {urls.map{$0.standardizedFileURL.path}}
        guard version==1,self.primary.isFileURL,self.primary.standardizedFileURL==primary?.standardizedFileURL,
              paths(originalSources)==paths(sources),paths(self.destinations)==paths(destinations),
              destinations.contains(where:{$0.standardizedFileURL==self.primary.standardizedFileURL}) else {
            throw CopyError.verifyFailed("Saved SSD checkpoint does not match this job.")
        }
        var seen=Set<String>()
        for file in files {
            let components=file.relativePath.split(separator:"/",omittingEmptySubsequences:false)
            guard !components.isEmpty,components.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
                  !file.relativePath.contains("\0"),file.size>=0,
                  file.checksum.count==16,file.checksum.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
                  seen.insert(file.relativePath.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw CopyError.verifyFailed("Invalid file record in saved SSD checkpoint.")
            }
        }
    }
}
