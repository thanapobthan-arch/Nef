import Foundation
import CryptoKit
import Darwin

// ASC MHL 2.0: XXH64 file/directory hashes and C4-linked nested histories.
// Completeness applies to the selected root except explicitly ignored metadata.
// Cross-history moves use explicit NefCopy receipts and exact-path retirement.
// Other algorithms and collections remain unsupported.
enum ASCMHL {
    static let manifestNS="urn:ASC:MHL:v2.0", chainNS="urn:ASC:MHL:DIRECTORY:v2.0"
    struct Failure:LocalizedError {let message:String;var errorDescription:String? {"ASC MHL: "+message}}
    struct FileEntry {let path:String;let size:Int64;let hash:String;let modified:Date}
    struct Generation {let number:Int;let path:String;let c4:String}
    struct DirectoryHash:Equatable {let content:String;let structure:String}
    struct TransferPayload:Codable,Equatable {
        let id:String,source:String,destination:String,sourceOwner:String,destinationOwner:String,hash:String,originC4:String
        let size:Int64
    }
    struct TransferNote:Codable,Equatable {let payload:TransferPayload;let role:String;let scope:String}
    struct LocatedTransfer {let location:String;let note:TransferNote}
    struct History {
        let generations:[Generation];let files:[String:FileEntry]
        var directories:[String:DirectoryHash]=[:]
        var references:[String:String]=[:]
        var nestedFingerprints:[String:[String]]=[:]
        var transfers:[LocatedTransfer]=[]
        var retired:[String:String]=[:]
        var redirects:[String:String]=[:]
    }
    struct Verification {
        let files:Int;let bytes:Int64;let generations:Int
        var transferredOut=0;var transferLinks=0;var pendingTransfers=0
    }
    private static func fail(_ message:String)->Failure {Failure(message:message)}
    static func c4(_ data:Data)->String {
        let alphabet=Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var bytes=Array(SHA512.hash(data:data)),digits=""
        while bytes.contains(where:{$0 != 0}) {
            var remainder=0
            for i in bytes.indices {let value=remainder*256+Int(bytes[i]);bytes[i]=UInt8(value/58);remainder=value%58}
            digits=String(alphabet[remainder])+digits
        }
        return "c4"+String(repeating:"1",count:88-digits.count)+digits
    }
    private static func date(_ value:Date)->String {
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:value)
    }
    private static func validPath(_ path:String,allowHistory:Bool=false)throws {
        let parts=path.components(separatedBy:"/")
        guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\\"),
              parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
              !path.unicodeScalars.contains(where:{$0.value<32 || $0.value==0xFFFE || $0.value==0xFFFF}),
              (allowHistory || !parts.contains(where:{$0.lowercased()=="ascmhl"})) else {throw fail("Unsafe or unsupported path: "+path)}
    }
    // Check each component, rather than resolving a symlink and trusting its target.
    private static func child(_ path:String,root:URL,regular:Bool=true,allowHistory:Bool=false)throws->URL {
        try validPath(path,allowHistory:allowHistory)
        var url=root
        for (index,part) in path.components(separatedBy:"/").enumerated() {
            url.appendPathComponent(part)
            let a=try FileManager.default.attributesOfItem(atPath:url.path)
            let last=index==path.components(separatedBy:"/").count-1
            guard a[.type] as? FileAttributeType == (last && regular ? .typeRegular:.typeDirectory) else {
                throw fail("Missing, symlinked, or wrong file type: "+path)
            }
        }
        return url
    }
    private static func metadata(_ url:URL)throws->(Int64,Date) {
        let a=try FileManager.default.attributesOfItem(atPath:url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,let n=a[.size] as? NSNumber,let t=a[.modificationDate] as? Date else {throw fail("Not a regular file: "+url.path)}
        return(n.int64Value,t)
    }
    static func hashFile(_ url:URL,checkpoint:()throws->Void = {})throws->(String,Int64,Date) {
        let before=try metadata(url);let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
        let h=XXH64BE();var bytes:Int64=0
        while true {
            try checkpoint()
            let data=try autoreleasepool {try handle.read(upToCount:8*1024*1024) ?? Data()}
            if data.isEmpty {break};h.update(data:data);bytes+=Int64(data.count)
        }
        let after=try metadata(url)
        guard before.0==after.0,before.1==after.1,bytes==before.0 else {throw fail("File changed while reading: "+url.path)}
        return(h.finalize().map{String(format:"%02x",$0)}.joined(),bytes,after.1)
    }
    private static func elements(_ root:XMLElement,_ name:String?=nil)->[XMLElement] {
        (root.children ?? []).compactMap{$0 as? XMLElement}.filter{name == nil || $0.localName==name}
    }
    private static func one(_ root:XMLElement,_ name:String)throws->XMLElement {
        let found=elements(root,name);guard found.count==1 else {throw fail("Expected exactly one "+name)};return found[0]
    }
    private static func text(_ root:XMLElement,_ name:String)throws->String {try one(root,name).stringValue ?? ""}
    private static func xml(_ url:URL,namespace:String,rootName:String)throws->XMLElement {
        let info=try metadata(url);guard info.0<=32*1024*1024 else {throw fail("XML file exceeds 32 MiB limit")}
        let data=try Data(contentsOf:url)
        guard let raw=String(data:data,encoding:.utf8),!raw.uppercased().contains("<!DOCTYPE"),!raw.uppercased().contains("<!ENTITY") else {throw fail("Invalid UTF-8 or prohibited XML entity declaration")}
        let document=try XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever])
        guard let root=document.rootElement(),root.localName==rootName,root.uri==namespace else {throw fail("Wrong XML root, namespace, or version")}
        func check(_ e:XMLElement)throws {
            if e.localName=="metadata",e.uri==namespace {return}
            guard e.uri==namespace else {throw fail("Mixed XML namespaces are unsupported")}
            for child in elements(e) {try check(child)}
        }
        try check(root);return root
    }
    private static func checkHash(_ hash:String)throws {
        guard hash.count==16,hash.allSatisfy({"0123456789abcdef".contains($0)}) else {throw fail("Invalid XXH64 checksum")}
    }
    private static func mhlDirectory(_ root:URL,create:Bool)throws->URL {
        let directory=root.appendingPathComponent("ascmhl",isDirectory:true)
        if !FileManager.default.fileExists(atPath:directory.path),create {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        }
        let a=try FileManager.default.attributesOfItem(atPath:directory.path)
        guard a[.type] as? FileAttributeType == .typeDirectory else {throw fail("ascmhl must be a real directory, not a symlink")}
        return directory
    }
    static func load(root:URL,depth:Int=0)throws->History {
        guard depth<32 else {throw fail("Nested history depth exceeds 32")}
        let directory=try mhlDirectory(root,create:false),chainURL=directory.appendingPathComponent("ascmhl_chain.xml")
        let chain=try xml(chainURL,namespace:chainNS,rootName:"ascmhldirectory")
        guard !elements(chain).isEmpty,elements(chain).allSatisfy({$0.localName=="hashlist"}) else {throw fail("Empty or unsupported chain")}
        var generations:[Generation]=[],files:[String:FileEntry]=[:],names=Set<String>()
        var directories:[String:DirectoryHash]=[:],references:[String:String]=[:],children:[String:History]=[:]
        var transferNotes:[String:TransferNote]=[:],latestPatterns=Set<String>(),redirects:[String:String]=[:]
        for item in elements(chain) {
            guard let number=Int(item.attribute(forName:"sequencenr")?.stringValue ?? ""),number==generations.count+1 else {throw fail("Non-contiguous generation sequence")}
            let path=try text(item,"path"),digest=try text(item,"c4")
            try validPath(path)
            guard !path.contains("/"),path.hasPrefix(String(format:"%04d_",number)),path.hasSuffix(".mhl"),names.insert(path).inserted,
                  elements(item).count==2 else {throw fail("Invalid or duplicated generation path")}
            let url=try child(path,root:directory)
            guard try metadata(url).0<=32*1024*1024 else {throw fail("Manifest exceeds 32 MiB limit")}
            let data=try Data(contentsOf:url)
            guard c4(data)==digest else {throw fail("Manifest C4 mismatch: "+path)}
            let manifest=try xml(url,namespace:manifestNS,rootName:"hashlist")
            guard manifest.attribute(forName:"version")?.stringValue=="2.0" else {throw fail("Unsupported manifest version")}
            _=try one(manifest,"creatorinfo");let process=try one(manifest,"processinfo")
            let priorDirectories=directories
            latestPatterns=Set(elements(process,"ignore").flatMap{elements($0,"pattern").compactMap{$0.stringValue}})
            for container in elements(manifest,"metadata") {
                for entry in elements(container) where entry.localName=="transferReceipts" && entry.uri==transferNS {
                    guard let text=entry.stringValue,let bytes=Data(base64Encoded:text) else {throw fail("Invalid transfer receipt encoding")}
                    for note in try JSONDecoder().decode([TransferNote].self,from:bytes) {
                        try validateNote(note)
                        let key=note.payload.id+"/"+note.role
                        if let previous=transferNotes[key],previous != note {throw fail("Transfer receipt was rewritten")}
                        transferNotes[key]=note
                    }
                }
            }
            if let value=elements(process,"roothash").first {directories=["":try parseDirectory(value)]}
            for container in elements(manifest,"references") {
                for reference in elements(container) {
                    guard reference.localName=="hashlistreference" else {throw fail("Unsupported reference type")}
                    let path=try text(reference,"path"),digest=try text(reference,"c4")
                    try validPath(path,allowHistory:true)
                    let parts=path.components(separatedBy:"/")
                    guard parts.count>=3,parts[parts.count-2]=="ascmhl",!parts.dropLast(2).contains("ascmhl") else {throw fail("Reference must target a descendant history")}
                    let target=try child(path,root:root,allowHistory:true)
                    guard c4(try Data(contentsOf:target))==digest else {throw fail("Nested reference C4 mismatch: "+path)}
                    let prefix=parts.dropLast(2).joined(separator:"/")
                    let history:History
                    if let cached=children[prefix] {history=cached} else {
                        history=try load(root:root.appendingPathComponent(prefix),depth:depth+1);children[prefix]=history
                    }
                    guard history.generations.contains(where:{$0.path==parts.last! && $0.c4==digest}) else {throw fail("Referenced manifest not in child chain")}
                    references[prefix]=path
                }
            }
            let hashes=elements(manifest,"hashes").first ?? XMLElement(name:"hashes");var seen=Set<String>()
            var directoryMoves:[String:String]=[:]
            for row in elements(hashes) where row.localName=="directoryhash" && !elements(row,"previousPath").isEmpty {
                let previous=try text(row,"previousPath"),current=try text(row,"path")
                try validPath(previous);try validPath(current)
                let value=try parseDirectory(row)
                guard previous != current,let old=priorDirectories[previous],old.content==value.content,
                      !references.keys.contains(where:{$0==previous || $0.hasPrefix(previous+"/")}) else {throw fail("Invalid directory rename or moved nested history")}
                directoryMoves[previous]=current
            }
            let beforeDirectoryMoves=files
            for entry in beforeDirectoryMoves.values where directoryMoves.keys.contains(where:{entry.path.hasPrefix($0+"/")}) {files.removeValue(forKey:entry.path)}
            for entry in beforeDirectoryMoves.values {
                if let previous=directoryMoves.keys.filter({entry.path.hasPrefix($0+"/")}).sorted(by:{$0.count>$1.count}).first {
                    let target=directoryMoves[previous]!+entry.path.dropFirst(previous.count)
                    guard files[target]==nil else {throw fail("Directory rename collision")}
                    files[target]=FileEntry(path:target,size:entry.size,hash:entry.hash,modified:entry.modified);redirects[entry.path]=target
                }
            }
            for row in elements(hashes) {
                let previousNodes=elements(row,"previousPath")
                guard previousNodes.count<=1 else {throw fail("Duplicate previousPath")}
                let previousPath=previousNodes.first?.stringValue
                if let previousPath {try validPath(previousPath)}
                if row.localName=="directoryhash" {
                    let name=try text(row,"path");try validPath(name)
                    guard seen.insert(name).inserted else {throw fail("Duplicate directory entry")}
                    directories[name]=try parseDirectory(row);continue
                }
                guard row.localName=="hash",elements(row).count==(previousPath==nil ? 2:3) else {throw fail("Unsupported directory entry or hash algorithm")}
                let pathNode=try one(row,"path"),name=pathNode.stringValue ?? "",hashNode=try one(row,"xxh64")
                try validPath(name);let hash=hashNode.stringValue ?? "";try checkHash(hash)
                let size:Int64
                if let raw=pathNode.attribute(forName:"size")?.stringValue {
                    guard let parsed=Int64(raw),parsed>=0 else {throw fail("Invalid file size")};size=parsed
                } else {size = -1} // size is optional in the ASC schema (reference omits zero).
                guard seen.insert(name).inserted,
                      let action=hashNode.attribute(forName:"action")?.stringValue,["original","verified"].contains(action) else {throw fail("Invalid, failed, or duplicated file entry")}
                if let recordedPrevious=previousPath {
                    var oldPath=recordedPrevious
                    if files[oldPath]==nil,let moved=directoryMoves.keys.filter({oldPath.hasPrefix($0+"/")}).sorted(by:{$0.count>$1.count}).first {
                        oldPath=directoryMoves[moved]!+oldPath.dropFirst(moved.count)
                    }
                    let mappedByDirectory=oldPath != recordedPrevious && oldPath==name
                    guard (oldPath != name || mappedByDirectory),let original=files[oldPath],
                          (files[name]==nil || mappedByDirectory),original.hash==hash,
                          (original.size<0 || size<0 || original.size==size) else {throw fail("Invalid or conflicting rename history")}
                    files.removeValue(forKey:oldPath);redirects[recordedPrevious]=name
                }
                if let previous=files[name],previous.hash != hash || (previous.size>=0 && size>=0 && previous.size != size) {throw fail("Conflicting checksum history: "+name)}
                files[name]=FileEntry(path:name,size:size>=0 ? size:(files[name]?.size ?? -1),hash:hash,modified:Date(timeIntervalSince1970:0))
            }
            generations.append(Generation(number:number,path:path,c4:digest))
        }
        let diskNames=Set(try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasSuffix(".mhl")})
        guard diskNames==names else {throw fail("Unchained/missing manifests or empty history")}
        var retired:[String:String]=[:],transfers=transferNotes.values.map{LocatedTransfer(location:"",note:$0)}
        for note in transferNotes.values where note.role=="outgoing" {
            let path=try localTransferPath(note.payload.source,owner:note.scope)
            guard let original=files[path],original.hash==note.payload.hash,(original.size<0 || original.size==note.payload.size),
                  generations.contains(where:{$0.c4==note.payload.originC4}),latestPatterns.contains(exactIgnore(path)) else {throw fail("Transfer retirement is not anchored to original history and an exact ignore")}
            files.removeValue(forKey:path);retired[path]=note.payload.id
        }
        var fingerprints:[String:[String]]=[:]
        for (prefix,history) in children {
            for entry in history.files.values {
                let path=prefix+"/"+entry.path
                guard files[path]==nil else {throw fail("File recorded in both parent and child history: "+path)}
                files[path]=FileEntry(path:path,size:entry.size,hash:entry.hash,modified:entry.modified)
            }
            transfers+=history.transfers.map{LocatedTransfer(location:$0.location.isEmpty ? prefix:prefix+"/"+$0.location,note:$0.note)}
            for (path,id) in history.retired {retired[prefix+"/"+path]=id}
            for (path,target) in history.redirects {redirects[prefix+"/"+path]=prefix+"/"+target}
            fingerprints[prefix]=history.generations.map{$0.c4}
            for (path,values) in history.nestedFingerprints {fingerprints[prefix+"/"+path]=values}
        }
        guard !files.isEmpty || !transferNotes.isEmpty else {throw fail("Empty history")}
        return History(generations:generations,files:files,directories:directories,references:references,nestedFingerprints:fingerprints,transfers:transfers,retired:retired,redirects:redirects)
    }
    static func verify(root:URL,checkpoint:()throws->Void = {})throws->Verification {
        let canonical=root.standardizedFileURL.resolvingSymlinksInPath()
        let context=try load(root:canonical)
        return try verifyScoped(root:canonical,contextRoot:canonical,context:context,checkpoint:checkpoint)
    }
    private static func verifyScoped(root canonical:URL,contextRoot:URL,context:History,checkpoint:()throws->Void)throws->Verification {
        let history=try load(root:canonical);var bytes:Int64=0
        for prefix in history.references.keys { _=try verifyScoped(root:canonical.appendingPathComponent(prefix),contextRoot:contextRoot,context:context,checkpoint:checkpoint) }
        for path in history.retired.keys where try hasExactPath(root:canonical,path:path) {throw fail("A moved-out source path reappeared: "+path)}
        for entry in history.files.values.sorted(by:{$0.path<$1.path}) {
            try checkpoint();let url=try child(entry.path,root:canonical)
            let (hash,size,_)=try hashFile(url,checkpoint:checkpoint)
            guard hash==entry.hash,(entry.size<0 || size==entry.size) else {throw fail("File checksum/size mismatch: "+entry.path)};bytes+=size
        }
        if !history.directories.isEmpty {
            let calculated=try directoryHashes(root:canonical,files:history.files,checkpoint:checkpoint)
            for (path,value) in history.directories {
                guard calculated[path]==value else {throw fail("Directory content/structure mismatch: "+(path.isEmpty ? ".":path))}
            }
        }
        // Detect a chain changing while the media files were being checked.
        let after=try load(root:canonical)
        guard after.generations.map({$0.c4})==history.generations.map({$0.c4}),after.nestedFingerprints==history.nestedFingerprints else {throw fail("History changed during verification")}
        var result=Verification(files:history.files.count,bytes:bytes,generations:history.generations.count)
        result.transferredOut=Set(history.transfers.filter{$0.note.role=="outgoing"}.map{$0.note.payload.id}).count
        let assessment=try validateTransferLinks(history:history,context:context,contextRoot:contextRoot,checkpoint:checkpoint)
        result.transferLinks=assessment.0;result.pendingTransfers=assessment.1
        return result
    }
    // ASC verification records its results as a new generation. The read-only
    // verify() above is also exposed internally for audits and compatibility tests.
    static func verifyAndRecord(root:URL,checkpoint:()throws->Void = {})throws->Verification {
        let started=Date(),canonical=root.standardizedFileURL.resolvingSymlinksInPath()
        let result=try verify(root:canonical,checkpoint:checkpoint),history=try load(root:canonical)
        guard result.pendingTransfers==0 else {return result}
        let records=history.files.values.map {entry in
            ChecksumRecord(file:entry.path,source:canonical.appendingPathComponent(entry.path).path,
                           destination:canonical.appendingPathComponent(entry.path).path,
                           sourceChecksum:entry.hash,destinationChecksum:entry.hash,status:"PASS")
        }
        _=try appendVerified(root:canonical,records:records,started:started,checkpoint:checkpoint)
        return Verification(files:result.files,bytes:result.bytes,generations:result.generations+1)
    }

    static func hasExactPath(root:URL,path:String)throws->Bool {
        try validPath(path);var directory=root
        let parts=path.components(separatedBy:"/")
        for (index,part) in parts.enumerated() {
            guard try FileManager.default.contentsOfDirectory(atPath:directory.path).contains(part) else {return false}
            directory.appendPathComponent(part)
            if index<parts.count-1 {
                let a=try FileManager.default.attributesOfItem(atPath:directory.path)
                guard a[.type] as? FileAttributeType == .typeDirectory else {throw fail("Unsafe previous path")}
            }
        }
        return true
    }
    // Records a move already made by the user. It never moves media or guesses
    // identity from matching hashes; old/new paths are explicit and fully checked.
    static func recordRename(root:URL,previousPath:String,newPath:String,started:Date=Date(),checkpoint:()throws->Void = {})throws->Verification {
        let canonical=root.standardizedFileURL.resolvingSymlinksInPath()
        try validPath(previousPath);try validPath(newPath)
        let history=try load(root:canonical)
        let previousStillExists=try hasExactPath(root:canonical,path:previousPath)
        guard previousPath != newPath,let original=history.files[previousPath],history.files[newPath]==nil,!previousStillExists else {
            throw fail("Choose an absent recorded old path and an unrecorded new file; copies/collisions are not renames")
        }
        let target=try child(newPath,root:canonical),value=try hashFile(target,checkpoint:checkpoint)
        guard original.hash==value.0,(original.size<0 || original.size==value.1) else {throw fail("Renamed file checksum differs from its original")}
        var proposed=history.files;proposed.removeValue(forKey:previousPath)
        proposed[newPath]=FileEntry(path:newPath,size:value.1,hash:value.0,modified:value.2)
        // No other media file can change or disappear as a side effect of recording a rename.
        for entry in proposed.values {
            let url=try child(entry.path,root:canonical),actual=try hashFile(url,checkpoint:checkpoint)
            guard actual.0==entry.hash,(entry.size<0 || actual.1==entry.size) else {throw fail("Another recorded file changed: "+entry.path)}
        }
        _=try directoryHashes(root:canonical,files:proposed,checkpoint:checkpoint)
        func owner(_ path:String)->String? {history.references.keys.filter{path.hasPrefix($0+"/")}.sorted{$0.count>$1.count}.first}
        let oldOwner=owner(previousPath),newOwner=owner(newPath)
        guard oldOwner==newOwner else {throw fail("Moving media across history ownership boundaries requires explicit history migration")}
        if let prefix=oldOwner {
            _=try recordRename(root:canonical.appendingPathComponent(prefix),previousPath:String(previousPath.dropFirst(prefix.count+1)),newPath:String(newPath.dropFirst(prefix.count+1)),started:started,checkpoint:checkpoint)
            let updated=try load(root:canonical)
            let records=updated.files.values.map {entry in ChecksumRecord(file:entry.path,source:canonical.appendingPathComponent(entry.path).path,destination:canonical.appendingPathComponent(entry.path).path,sourceChecksum:entry.hash,destinationChecksum:entry.hash,status:"PASS")}
            _=try appendVerified(root:canonical,records:records,started:started,checkpoint:checkpoint)
        } else {
            let records=proposed.values.map {entry in ChecksumRecord(file:entry.path,source:canonical.appendingPathComponent(entry.path).path,destination:canonical.appendingPathComponent(entry.path).path,sourceChecksum:entry.hash,destinationChecksum:entry.hash,status:"PASS")}
            _=try appendVerified(root:canonical,records:records,started:started,renames:[previousPath:newPath],checkpoint:checkpoint)
        }
        return try verify(root:canonical,checkpoint:checkpoint)
    }

    static func retainedArtifacts(entries:[CopyEntry],destination:URL)throws->Set<String> {
        var retained=Set<String>(),checked:[String:Bool]=[:]
        for entry in entries {
            let parts=entry.relativePath.components(separatedBy:"/")
            guard let index=parts.firstIndex(of:"ascmhl") else {continue}
            let prefix=parts.prefix(index).joined(separator:"/")
            if checked[prefix]==nil {
                let target=destination.appendingPathComponent(prefix)
                if FileManager.default.fileExists(atPath:target.appendingPathComponent("ascmhl").path) {
                    var source=entry.source
                    for _ in index..<parts.count {source.deleteLastPathComponent()}
                    let original=try load(root:source),current=try load(root:target)
                    guard current.generations.count>=original.generations.count,
                          Array(current.generations.prefix(original.generations.count)).map({$0.c4})==original.generations.map({$0.c4}) else {
                        throw fail("Conflicting ASC histories require explicit reconciliation: "+prefix)
                    }
                    checked[prefix]=true
                } else {checked[prefix]=false}
            }
            if checked[prefix]==true {retained.insert(entry.source.path)}
        }
        return retained
    }
    static func artifacts(root:URL)throws->[URL] {
        let history=try load(root:root)
        var values=[root.appendingPathComponent("ascmhl/ascmhl_chain.xml")]
        values+=history.generations.map{root.appendingPathComponent("ascmhl/"+$0.path)}
        for prefix in history.references.keys {values+=try artifacts(root:root.appendingPathComponent(prefix))}
        return values
    }
    private static func parseDirectory(_ row:XMLElement)throws->DirectoryHash {
        let content=try one(row,"content"),structure=try one(row,"structure")
        guard elements(content).count==1,elements(structure).count==1 else {throw fail("Unsupported directory hash algorithm")}
        let c=try text(content,"xxh64"),s=try text(structure,"xxh64");try checkHash(c);try checkHash(s)
        return DirectoryHash(content:c,structure:s)
    }
    private static func digest(_ data:Data)->String {let h=XXH64BE();h.update(data:data);return h.finalize().map{String(format:"%02x",$0)}.joined()}
    private static func hashBytes(_ text:String)->Data {
        Data(stride(from:0,to:text.count,by:2).map {n in
            let a=text.index(text.startIndex,offsetBy:n),b=text.index(a,offsetBy:2)
            return UInt8(text[a..<b],radix:16)!
        })
    }
    private static func hashList(_ values:[String])->String {digest(values.sorted().reduce(into:Data()){$0.append(hashBytes($1))})}
    private static func ignored(_ name:String)->Bool {name=="ascmhl" || name=="NefCopy Reports" || name==".DS_Store" || name.hasPrefix(".nefcopy-")}
    private static func nestedRoots(root:URL)throws->[String] {
        var result:[String]=[]
        func walk(_ directory:URL,_ prefix:String)throws {
            for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
                if ignored(url.lastPathComponent) {continue}
                let a=try FileManager.default.attributesOfItem(atPath:url.path)
                guard a[.type] as? FileAttributeType != .typeSymbolicLink else {throw fail("Symlink in directory scope: "+url.path)}
                if a[.type] as? FileAttributeType == .typeDirectory {
                    let path=prefix.isEmpty ? url.lastPathComponent:prefix+"/"+url.lastPathComponent
                    if FileManager.default.fileExists(atPath:url.appendingPathComponent("ascmhl").path) {_=try mhlDirectory(url,create:false);result.append(path)} else {try walk(url,path)}
                }
            }
        }
        try walk(root,"");return result.sorted()
    }
    private static func directoryHashes(root:URL,files:[String:FileEntry],checkpoint:()throws->Void)throws->[String:DirectoryHash] {
        var result:[String:DirectoryHash]=[:],seen=Set<String>()
        func walk(_ directory:URL,_ prefix:String)throws->DirectoryHash {
            var contents:[String]=[],structures:[String]=[]
            for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
                try checkpoint();let name=url.lastPathComponent;if ignored(name) {continue}
                let path=prefix.isEmpty ? name:prefix+"/"+name;try validPath(path)
                let a=try FileManager.default.attributesOfItem(atPath:url.path)
                switch a[.type] as? FileAttributeType {
                case .typeRegular:
                    guard let entry=files[path] else {throw fail("Unlisted file prevents complete directory hash: "+path)}
                    seen.insert(path);contents.append(entry.hash);structures.append(digest(Data(name.utf8)+hashBytes(entry.hash)))
                case .typeDirectory:
                    let hash=try walk(url,path);contents.append(hash.content);structures.append(digest(Data(name.utf8)+hashBytes(hash.structure)))
                default:throw fail("Unsupported file type in directory scope: "+path)
                }
            }
            let value=DirectoryHash(content:hashList(contents),structure:hashList(structures));result[prefix]=value;return value
        }
        _=try walk(root,"")
        guard seen==Set(files.keys) else {throw fail("Directory scope is missing recorded files")};return result
    }
    private static func directoryNode(_ name:String,_ value:DirectoryHash,_ stamp:String)->XMLElement {
        let row=XMLElement(name:name)
        for (key,hash) in [("content",value.content),("structure",value.structure)] {
            let container=XMLElement(name:key),entry=node("xxh64",hash)
            entry.addAttribute(XMLNode.attribute(withName:"hashdate",stringValue:stamp) as! XMLNode);container.addChild(entry);row.addChild(container)
        }
        return row
    }

    private static func node(_ name:String,_ value:String)->XMLElement {XMLElement(name:name,stringValue:value)}
    private static func document(_ root:XMLElement)->Data {
        let d=XMLDocument(rootElement:root);d.version="1.0";d.characterEncoding="UTF-8";return d.xmlData(options:[.nodePrettyPrint])
    }
    static func appendVerified(root:URL,records:[ChecksumRecord],started:Date=Date(),restoreRecordedEmptyDirectories:Bool=false,renames:[String:String]=[:],transferNotes:[TransferNote]=[],checkpoint:()throws->Void = {})throws->URL {
        let root=root.standardizedFileURL.resolvingSymlinksInPath(),directory=try mhlDirectory(root,create:true)
        let lock=directory.appendingPathComponent(".nefcopy-ascmhl.lock")
        let fd=lock.withUnsafeFileSystemRepresentation{Darwin.open($0!,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o600))}
        guard fd>=0 else {throw fail("History is locked by another writer; inspect the lock after an interrupted write")}
        defer {Darwin.close(fd);try? FileManager.default.removeItem(at:lock)}
        let chainURL=directory.appendingPathComponent("ascmhl_chain.xml")
        let old:History
        if FileManager.default.fileExists(atPath:chainURL.path) {old=try load(root:root)} else {
            let contents=try FileManager.default.contentsOfDirectory(atPath:directory.path)
            guard contents.allSatisfy({$0==lock.lastPathComponent}) else {throw fail("Existing history has no chain; nothing overwritten")}
            old=History(generations:[],files:[:])
        }
        var notes=old.transfers.filter{$0.location.isEmpty}.map{$0.note}
        for note in transferNotes {
            try validateNote(note)
            if let existing=notes.first(where:{$0.payload.id==note.payload.id && $0.role==note.role}) {guard existing==note else {throw fail("Conflicting transfer receipt")}} else {notes.append(note)}
        }
        if restoreRecordedEmptyDirectories {
            let empty=DirectoryHash(content:digest(Data()),structure:digest(Data()))
            for (path,value) in old.directories where !path.isEmpty && value==empty {
                try validPath(path);var target=root
                for component in path.components(separatedBy:"/") {
                    target.appendPathComponent(component)
                    if FileManager.default.fileExists(atPath:target.path) {
                        let attributes=try FileManager.default.attributesOfItem(atPath:target.path)
                        guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw fail("Unsafe recorded empty directory")}
                    } else {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)}
                }
            }
        }
        let nested=try nestedRoots(root:root)
        guard !records.isEmpty || !nested.isEmpty || !notes.isEmpty else {throw fail("No verified files to record")}
        var references:[String:Generation]=[:],nestedFiles:[String:FileEntry]=[:]
        for prefix in nested {
            let childRoot=root.appendingPathComponent(prefix)
            let childRecords=records.filter { URL(fileURLWithPath:$0.destination).standardizedFileURL.path.hasPrefix(childRoot.path+"/") }
            let current=try load(root:childRoot)
            let input=childRecords.isEmpty ? current.files.values.map {entry in
                ChecksumRecord(file:entry.path,source:childRoot.appendingPathComponent(entry.path).path,destination:childRoot.appendingPathComponent(entry.path).path,sourceChecksum:entry.hash,destinationChecksum:entry.hash,status:"PASS")
            }:childRecords
            _=try appendVerified(root:childRoot,records:input,started:started,restoreRecordedEmptyDirectories:restoreRecordedEmptyDirectories,checkpoint:checkpoint)
            let updated=try load(root:childRoot)
            references[prefix]=updated.generations.last!
            for entry in updated.files.values {
                let path=prefix+"/"+entry.path;nestedFiles[path]=FileEntry(path:path,size:entry.size,hash:entry.hash,modified:entry.modified)
            }
        }
        var files=old.files.filter {path,_ in !nested.contains(where:{path.hasPrefix($0+"/")})},seen=Set<String>()
        for note in notes where note.role=="outgoing" {
            let path=try localTransferPath(note.payload.source,owner:note.scope)
            if let original=files[path] {
                guard original.hash==note.payload.hash,(original.size<0 || original.size==note.payload.size),old.generations.contains(where:{$0.c4==note.payload.originC4}) else {throw fail("Transfer source checksum changed")}
                files.removeValue(forKey:path)
            } else {guard old.retired[path]==note.payload.id else {throw fail("Transfer source is not in original history")}}
            guard try !hasExactPath(root:root,path:path) else {throw fail("Moved-out source still exists")}
        }
        for (previous,current) in renames {
            try validPath(previous);try validPath(current)
            guard let entry=files[previous],files[current]==nil,previous != current else {throw fail("Rename conflicts with current history")}
            files.removeValue(forKey:previous);files[current]=FileEntry(path:current,size:entry.size,hash:entry.hash,modified:entry.modified)
        }
        for record in records {
            guard record.status=="PASS",record.sourceChecksum==record.destinationChecksum else {throw fail("Only checksum-verified copies can be recorded")}
            let target=URL(fileURLWithPath:record.destination).standardizedFileURL
            let prefix=root.pathComponents,parts=target.pathComponents
            guard parts.count>prefix.count,parts.starts(with:prefix) else {throw fail("Destination outside manifest scope")}
            let path=parts.dropFirst(prefix.count).joined(separator:"/")
            if nested.contains(where:{path.hasPrefix($0+"/")}) {continue}
            try validPath(path);try checkHash(record.destinationChecksum)
            guard seen.insert(path).inserted else {throw fail("Duplicate destination entry")}
            let url=try child(path,root:root);let meta=try metadata(url)
            if let previous=files[path],previous.hash != record.destinationChecksum || (previous.size>=0 && previous.size != meta.0) {throw fail("Refusing to replace historical checksum: "+path)}
            files[path]=FileEntry(path:path,size:meta.0,hash:record.destinationChecksum,modified:meta.1)
        }
        var checked:[FileEntry]=[]
        // Freshly read back every listed file, including prior generations. A
        // metadata-only copy skip must never become an ASC 'verified' assertion.
        for entry in files.values.sorted(by:{$0.path<$1.path}) {
            try checkpoint();let url=try child(entry.path,root:root);let (hash,size,modified)=try hashFile(url,checkpoint:checkpoint)
            guard hash==entry.hash,(entry.size<0 || size==entry.size) else {throw fail("Cannot record verified history for changed file: "+entry.path)}
            checked.append(FileEntry(path:entry.path,size:size,hash:hash,modified:modified))
        }
        var allFiles=nestedFiles
        for entry in checked {allFiles[entry.path]=entry}
        let directoryValues=try directoryHashes(root:root,files:allFiles,checkpoint:checkpoint)
        var directoryRenames:[String:String]=[:]
        if !renames.isEmpty {
            for (previous,value) in old.directories where !previous.isEmpty && directoryValues[previous]==nil {
                guard renames.keys.contains(where:{$0.hasPrefix(previous+"/")}) else {throw fail("Unrelated recorded directory disappeared")}
                let candidates=directoryValues.keys.filter {current in
                    !current.isEmpty && old.directories[current]==nil && directoryValues[current]?.content==value.content && renames.values.contains(where:{$0.hasPrefix(current+"/")})
                }
                guard candidates.count==1 else {throw fail("Removed directory cannot be linked unambiguously; preserve it or migrate its history explicitly")}
                directoryRenames[candidates[0]]=previous
            }
        }
        let stamp=date(started),n=old.generations.count+1
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyy-MM-dd_HHmmss'Z'"
        let name=String(format:"%04d_",n)+root.lastPathComponent+"_"+formatter.string(from:started)+".mhl"
        try validPath(name)
        let manifest=XMLElement(name:"hashlist");manifest.addNamespace(XMLNode.namespace(withName:"",stringValue:manifestNS) as! XMLNode)
        manifest.addAttribute(XMLNode.attribute(withName:"version",stringValue:"2.0") as! XMLNode)
        let creator=XMLElement(name:"creatorinfo");creator.addChild(node("creationdate",stamp));creator.addChild(node("hostname",ProcessInfo.processInfo.hostName))
        let tool=node("tool","NefCopy");tool.addAttribute(XMLNode.attribute(withName:"version",stringValue:"21.1.4.14") as! XMLNode);creator.addChild(tool)
        creator.addChild(node("comment","XXH64 file/directory hashes and nested ASC MHL histories."));manifest.addChild(creator)
        let process=XMLElement(name:"processinfo");process.addChild(node("process","in-place"))
        if let value=directoryValues[""] {process.addChild(directoryNode("roothash",value,stamp))}
        let ignore=XMLElement(name:"ignore");for value in ["ascmhl/","NefCopy Reports/",".nefcopy-*",".DS_Store"] {ignore.addChild(node("pattern",value))}
        var retirePaths=Set(old.retired.keys)
        for note in notes where note.role=="outgoing" {retirePaths.insert(try localTransferPath(note.payload.source,owner:note.scope))}
        for prefix in nested {let value=try load(root:root.appendingPathComponent(prefix));for path in value.retired.keys {retirePaths.insert(prefix+"/"+path)}}
        for path in retirePaths.sorted() {ignore.addChild(node("pattern",exactIgnore(path)))}
        process.addChild(ignore);manifest.addChild(process)
        let hashes=XMLElement(name:"hashes")
        for entry in checked {
            let row=XMLElement(name:"hash"),path=node("path",entry.path)
            path.addAttribute(XMLNode.attribute(withName:"size",stringValue:String(entry.size)) as! XMLNode)
            path.addAttribute(XMLNode.attribute(withName:"lastmodificationdate",stringValue:date(entry.modified)) as! XMLNode)
            let hash=node("xxh64",entry.hash);hash.addAttribute(XMLNode.attribute(withName:"action",stringValue:old.files[entry.path] == nil ? "original":"verified") as! XMLNode);hash.addAttribute(XMLNode.attribute(withName:"hashdate",stringValue:stamp) as! XMLNode)
            row.addChild(path);row.addChild(hash)
            if let previous=renames.first(where:{$0.value==entry.path})?.key {row.addChild(node("previousPath",previous))}
            hashes.addChild(row)
        }
        for (path,value) in directoryValues.sorted(by:{$0.key<$1.key}) where !path.isEmpty && !nested.contains(where:{path==$0 || path.hasPrefix($0+"/")}) {
            let row=directoryNode("directoryhash",value,stamp);row.insertChild(node("path",path),at:0)
            if let previous=directoryRenames[path] {row.addChild(node("previousPath",previous))}
            hashes.addChild(row)
        }
        if !checked.isEmpty || elements(hashes).count>0 {manifest.addChild(hashes)}
        if !notes.isEmpty {
            let metadata=XMLElement(name:"metadata"),value=node("transferReceipts",try JSONEncoder().encode(notes.sorted{$0.payload.id+$0.role<$1.payload.id+$1.role}).base64EncodedString())
            value.addNamespace(XMLNode.namespace(withName:"",stringValue:transferNS) as! XMLNode);metadata.addChild(value);manifest.addChild(metadata)
        }
        if !references.isEmpty {
            let container=XMLElement(name:"references")
            for (prefix,generation) in references.sorted(by:{$0.key<$1.key}) {
                let row=XMLElement(name:"hashlistreference");row.addChild(node("path",prefix+"/ascmhl/"+generation.path));row.addChild(node("c4",generation.c4));container.addChild(row)
            }
            manifest.addChild(container)
        }
        let data=document(manifest),manifestURL=directory.appendingPathComponent(name)
        let chain=XMLElement(name:"ascmhldirectory");chain.addNamespace(XMLNode.namespace(withName:"",stringValue:chainNS) as! XMLNode)
        for generation in old.generations+[Generation(number:n,path:name,c4:c4(data))] {
            let item=XMLElement(name:"hashlist");item.addAttribute(XMLNode.attribute(withName:"sequencenr",stringValue:String(generation.number)) as! XMLNode)
            item.addChild(node("path",generation.path));item.addChild(node("c4",generation.c4));chain.addChild(item)
        }
        try checkpoint()
        // Exclusive new manifest, atomic chain replacement. An interrupted write
        // may leave an orphan/lock; the next writer blocks rather than discards it.
        try data.write(to:manifestURL,options:[.withoutOverwriting])
        let manifestHandle=try FileHandle(forWritingTo:manifestURL);try manifestHandle.synchronize();try manifestHandle.close()
        try document(chain).write(to:chainURL,options:[.atomic])
        let handle=try FileHandle(forWritingTo:chainURL);try handle.synchronize();try handle.close()
        return manifestURL
    }
}

extension ASCMHL {
    static let transferNS="urn:NefCopy:ASC-MHL:transfer:v1"
    private static func localTransferPath(_ path:String,owner:String)throws->String {
        try validPath(path)
        if owner.isEmpty {return path}
        try validPath(owner)
        guard path.hasPrefix(owner+"/") else {throw fail("Transfer path outside owner")}
        return String(path.dropFirst(owner.count+1))
    }
    private static func exactIgnore(_ path:String)->String {
        // Anchored ASC/gitignore literal: never use a wildcard to hide a moved path.
        "/"+path.map {c in "*?[]\\ ".contains(c) ? "\\"+String(c):String(c)}.joined()
    }
    private static func validateNote(_ note:TransferNote)throws {
        let p=note.payload
        guard UUID(uuidString:p.id) != nil,p.source != p.destination,p.sourceOwner != p.destinationOwner,p.size>=0 else {throw fail("Invalid transfer receipt identity")}
        _=try localTransferPath(p.source,owner:p.sourceOwner);_=try localTransferPath(p.destination,owner:p.destinationOwner)
        try checkHash(p.hash)
        guard p.originC4.count==90,p.originC4.hasPrefix("c4") else {throw fail("Invalid original history reference")}
        switch note.role {
        case "outgoing":guard note.scope==p.sourceOwner else {throw fail("Wrong outgoing scope")}
        case "received":guard note.scope==p.destinationOwner else {throw fail("Wrong receiving scope")}
        case "link":guard note.scope.isEmpty else {throw fail("Transfer link must be anchored at the common root")}
        default:throw fail("Unsupported transfer role")
        }
    }
    private static func resolvedTransferPath(_ path:String,history:History)throws->String {
        var path=path,seen=Set<String>()
        while let next=history.redirects[path] {guard seen.insert(path).inserted else {throw fail("Ambiguous transfer rename lineage")};path=next}
        return path
    }
    private static func validateTransferLinks(history:History,context:History,contextRoot:URL,checkpoint:()throws->Void)throws->(Int,Int) {
        var payloads:[String:TransferPayload]=[:]
        for entry in context.transfers {
            let payload=entry.note.payload
            if let prior=payloads[payload.id],prior != payload {throw fail("Conflicting transfer payloads")}
            payloads[payload.id]=payload
        }
        var proven:[String:String]=[:],active=Set<String>()
        func prove(_ payload:TransferPayload)throws->String? {
            if let path=proven[payload.id] {return path}
            guard active.count<32,active.insert(payload.id).inserted else {throw fail("Transfer receipt cycle/depth limit")}
            defer {active.remove(payload.id)}
            let matching=context.transfers.filter{$0.note.payload.id==payload.id},links=matching.filter{$0.note.role=="link"}
            if links.count != 1 {
                if links.count>1 || (matching.contains(where:{$0.note.role=="outgoing"}) && matching.contains(where:{$0.note.role=="received"})) {throw fail("Common-parent transfer link is missing or ambiguous")}
                return nil
            }
            let anchor=links[0].location
            func full(_ path:String)->String {anchor.isEmpty ? path:(path.isEmpty ? anchor:anchor+"/"+path)}
            guard matching.count==3,matching.allSatisfy({$0.note.payload==payload && $0.location==full($0.note.scope)}) else {throw fail("Transfer evidence appears in the wrong scope or was duplicated")}
            for (role,owner) in [("outgoing",payload.sourceOwner),("received",payload.destinationOwner)] {
                guard matching.contains(where:{$0.location==full(owner) && $0.note.role==role}) else {throw fail("Missing peer transfer receipt")}
            }
            let ownerRoot=try child(full(payload.sourceOwner),root:contextRoot,regular:false)
            guard try load(root:ownerRoot).generations.contains(where:{$0.c4==payload.originC4}) else {throw fail("Original source generation is missing")}
            let actualPath=try resolvedTransferPath(full(payload.destination),history:context)
            if let expected=context.files[actualPath] {
                guard expected.hash==payload.hash,(expected.size<0 || expected.size==payload.size) else {throw fail("Transferred file identity changed")}
                let actual=try hashFile(child(actualPath,root:contextRoot),checkpoint:checkpoint)
                guard actual.0==payload.hash,actual.1==payload.size else {throw fail("Transferred destination checksum mismatch")}
                proven[payload.id]=actualPath;return actualPath
            }
            // A received file may subsequently move again. Follow only a fully
            // anchored outgoing receipt for that exact current path and checksum.
            var next:[TransferPayload]=[]
            for candidate in context.transfers where candidate.note.role=="outgoing" && candidate.note.payload.id != payload.id {
                let p=candidate.note.payload
                guard p.hash==payload.hash,p.size==payload.size,let link=context.transfers.first(where:{$0.note.role=="link" && $0.note.payload.id==p.id}) else {continue}
                let source=link.location.isEmpty ? p.source:link.location+"/"+p.source
                if try resolvedTransferPath(source,history:context)==actualPath {next.append(p)}
            }
            guard next.count==1 else {throw fail("Transferred file is missing or has ambiguous onward custody")}
            guard let final=try prove(next[0]) else {return nil}
            proven[payload.id]=final;return final
        }
        var verified=0,pending=0
        for id in Set(history.transfers.map{$0.note.payload.id}) {
            guard let payload=payloads[id] else {throw fail("Transfer receipt disappeared")}
            if try prove(payload) == nil {pending+=1} else {verified+=1}
        }
        return(verified,pending)
    }
    private static func transferOwner(root:URL,path:String)throws->String {
        var current=root,prefix="",relative=path
        for _ in 0..<32 {
            let history=try load(root:current)
            guard let next=history.references.keys.filter({relative.hasPrefix($0+"/")}).sorted(by:{$0.count>$1.count}).first else {return prefix}
            prefix=prefix.isEmpty ? next:prefix+"/"+next;relative=String(relative.dropFirst(next.count+1));current=current.appendingPathComponent(next)
        }
        throw fail("History ownership depth exceeded")
    }
    struct TransferJournal:Codable {let version:Int;let payload:TransferPayload;var state:String}
    static func pendingTransferPayloads(root:URL)throws->[TransferPayload] {
        var result:[TransferPayload]=[]
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where url.lastPathComponent.hasPrefix(".nefcopy-transfer-") && url.pathExtension=="json" {
            let value=try metadata(url);guard value.0<1024*1024 else {throw fail("Invalid transfer journal size")}
            let journal=try JSONDecoder().decode(TransferJournal.self,from:Data(contentsOf:url))
            guard journal.version==1 else {throw fail("Unsupported transfer journal")}
            try validateNote(TransferNote(payload:journal.payload,role:"outgoing",scope:journal.payload.sourceOwner))
            if journal.state != "complete" {result.append(journal.payload)}
        }
        return result.sorted{$0.id<$1.id}
    }
    // Metadata-only transfer: the user first moves the file, just as for recordRename.
    // A journal marks partial multi-history commits; success is returned only after
    // source, receiver and common parent and every receipt link verify together.
    static func recordCrossHistoryMove(root:URL,previousPath:String,newPath:String,checkpoint:()throws->Void = {})throws->Verification {
        let root=root.standardizedFileURL.resolvingSymlinksInPath()
        try validPath(previousPath);try validPath(newPath)
        guard previousPath != newPath,try !hasExactPath(root:root,path:previousPath) else {throw fail("Move the file first; the source path must be absent")}
        let history=try load(root:root),target=try child(newPath,root:root),actual=try hashFile(target,checkpoint:checkpoint)
        let journalName=".nefcopy-transfer-"+c4(Data((previousPath+"\u{0}"+newPath).utf8))+".json",journalURL=root.appendingPathComponent(journalName)
        let payload:TransferPayload
        if FileManager.default.fileExists(atPath:journalURL.path) {
            let info=try metadata(journalURL);guard info.0<1024*1024 else {throw fail("Invalid transfer journal size")}
            let saved=try JSONDecoder().decode(TransferJournal.self,from:Data(contentsOf:journalURL))
            guard saved.version==1,saved.payload.source==previousPath,saved.payload.destination==newPath,saved.state != "complete" else {throw fail("Transfer already recorded or journal conflicts")}
            payload=saved.payload
        } else {
            guard let original=history.files[previousPath],history.files[newPath]==nil,original.hash==actual.0,(original.size<0 || original.size==actual.1) else {throw fail("New file does not match an absent recorded source")}
            let sourceOwner=try transferOwner(root:root,path:previousPath),destinationOwner=try transferOwner(root:root,path:newPath)
            guard sourceOwner != destinationOwner,!sourceOwner.isEmpty,!destinationOwner.isEmpty else {throw fail("Choose two different nested histories under the common parent") }
            guard history.retired[newPath]==nil else {throw fail("A retired source path cannot be reused; choose a new destination name") }
            let originalHistory=try load(root:root.appendingPathComponent(sourceOwner))
            payload=TransferPayload(id:UUID().uuidString,source:previousPath,destination:newPath,sourceOwner:sourceOwner,destinationOwner:destinationOwner,hash:actual.0,originC4:originalHistory.generations.last!.c4,size:actual.1)
        }
        guard !payload.sourceOwner.isEmpty,!payload.destinationOwner.isEmpty,payload.hash==actual.0,payload.size==actual.1,
              try transferOwner(root:root,path:previousPath)==payload.sourceOwner,
              try transferOwner(root:root,path:newPath)==payload.destinationOwner else {throw fail("Transfer journal is inconsistent with verified media or ownership")}
        let origin=try load(root:root.appendingPathComponent(payload.sourceOwner))
        guard origin.generations.contains(where:{$0.c4==payload.originC4}) else {throw fail("Original transfer source history is missing")}
        var proposed=history.files;proposed.removeValue(forKey:previousPath)
        if let present=proposed[newPath],present.hash != payload.hash {throw fail("Destination identity conflicts with transfer")}
        proposed[newPath]=FileEntry(path:newPath,size:actual.1,hash:actual.0,modified:actual.2)
        for entry in proposed.values {
            let value=try hashFile(child(entry.path,root:root),checkpoint:checkpoint)
            guard value.0==entry.hash,(entry.size<0 || value.1==entry.size) else {throw fail("Another media file changed: "+entry.path)}
        }
        _=try directoryHashes(root:root,files:proposed,checkpoint:checkpoint)
        let lock=root.appendingPathComponent(".nefcopy-transfer-operation.lock")
        let fd=lock.withUnsafeFileSystemRepresentation{Darwin.open($0!,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o600))}
        guard fd>=0 else {throw fail("Transfer operation is locked; inspect an interrupted operation first")}
        defer {Darwin.close(fd);try? FileManager.default.removeItem(at:lock)}
        var journal=TransferJournal(version:1,payload:payload,state:"prepared")
        func save(_ state:String)throws {journal.state=state;try JSONEncoder().encode(journal).write(to:journalURL,options:.atomic)}
        try save("prepared")
        let started=Date(),sourceRoot=root.appendingPathComponent(payload.sourceOwner),destinationRoot=root.appendingPathComponent(payload.destinationOwner)
        func records(_ files:[String:FileEntry],at directory:URL)->[ChecksumRecord] {files.values.map{entry in ChecksumRecord(file:entry.path,source:directory.appendingPathComponent(entry.path).path,destination:directory.appendingPathComponent(entry.path).path,sourceChecksum:entry.hash,destinationChecksum:entry.hash,status:"PASS")}}
        do {
            let received=TransferNote(payload:payload,role:"received",scope:payload.destinationOwner)
            let targetRecord=ChecksumRecord(file:newPath,source:target.path,destination:target.path,sourceChecksum:payload.hash,destinationChecksum:payload.hash,status:"PASS")
            _=try appendVerified(root:destinationRoot,records:[targetRecord],started:started,transferNotes:[received],checkpoint:checkpoint)
            try save("destination-recorded");try checkpoint()
            let source=try load(root:sourceRoot),local=try localTransferPath(previousPath,owner:payload.sourceOwner)
            var remaining=source.files;remaining.removeValue(forKey:local)
            let outgoing=TransferNote(payload:payload,role:"outgoing",scope:payload.sourceOwner)
            _=try appendVerified(root:sourceRoot,records:records(remaining,at:sourceRoot),started:started,transferNotes:[outgoing],checkpoint:checkpoint)
            try save("source-retired");try checkpoint()
            let updated=try load(root:root)
            let link=TransferNote(payload:payload,role:"link",scope:"")
            _=try appendVerified(root:root,records:records(updated.files,at:root),started:started,transferNotes:[link],checkpoint:checkpoint)
            let result=try verify(root:root,checkpoint:checkpoint)
            guard result.pendingTransfers==0 else {throw fail("Transfer links are not completely verified")}
            try save("complete");return result
        } catch {try? save("needs-review-or-retry");throw error}
    }
}
