import Foundation

public struct NativeModels {
    public let root:URL,resources:URL
    public init(root:URL,resources:URL){self.root=root;self.resources=resources}
    public func ensure(design:Bool) throws->URL {
        let name=design ? "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit":"Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source"
        let spec=try NativeIO.load(resources.appendingPathComponent(design ? "design_model_files.json":"stress_model_files.json")),files=NativeIO.objects(spec["files"])
        let target=root.appendingPathComponent("models/"+name),total=files.reduce(0){$0+($1["size"] as? Int ?? 0)};var done=0
        for item in files {
            let relative=NativeIO.string(item["path"]),size=item["size"] as? Int ?? 0,sha=NativeIO.string(item["sha256"]),path=target.appendingPathComponent(relative)
            NativeIO.stage("Проверка модели · "+name+" · "+relative,Double(done)/Double(max(1,total)))
            if FileManager.default.fileExists(atPath:path.path){try validate(path,size:size,sha:sha);done += size;continue}
            let old=root.deletingLastPathComponent().appendingPathComponent("models/"+name+"/"+relative)
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:old.path){try validate(old,size:size,sha:sha);try FileManager.default.copyItem(at:old,to:path);done += size;continue}
            let partial=path.appendingPathExtension("partial")
            let remote="https://huggingface.co/"+NativeIO.string(spec["repo"])+"/resolve/"+NativeIO.string(spec["revision"])+"/"+relative
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/curl");process.arguments=["-fsSL","--connect-timeout","30","--speed-limit","1024","--speed-time","90","--retry","3","-C","-",remote,"-o",partial.path]
            let errorURL=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);FileManager.default.createFile(atPath:errorURL.path,contents:nil)
            let errorHandle=try FileHandle(forWritingTo:errorURL);defer{try? errorHandle.close();try? FileManager.default.removeItem(at:errorURL)}
            process.standardOutput=FileHandle.nullDevice;process.standardError=errorHandle
            let start=Date(), initial=fileSize(partial);try process.run();NativeIO.emit("child",["pid":process.processIdentifier])
            repeat {
                let current=fileSize(partial),rate=Double(max(0,current-initial))/max(0.01,Date().timeIntervalSince(start))
                NativeIO.stage(String(format:"Скачивание %@ · %@ · %.0f / %.0f МБ · %.1f МБ/с",design ? "VoiceDesign":"модели озвучки",relative,Double(done+current)/1048576,Double(total)/1048576,rate/1048576),min(1,Double(done+current)/Double(max(1,total))))
                Thread.sleep(forTimeInterval:1)
            }while process.isRunning
            process.waitUntilExit();NativeIO.emit("child",["pid":0]);guard process.terminationStatus == 0 else{throw StudioError("Не удалось скачать модель. Проверьте соединение и повторите: загрузка продолжится")}
            NativeIO.stage("Проверка контрольной суммы · "+relative,Double(done+size)/Double(max(1,total)))
            try validate(partial,size:size,sha:sha);try FileManager.default.moveItem(at:partial,to:path);done += size
        };return target
    }
    func fileSize(_ path:URL)->Int {(try? FileManager.default.attributesOfItem(atPath:path.path)[.size] as? Int) ?? 0}
    func validate(_ path:URL,size:Int,sha:String)throws{guard fileSize(path) == size,try sha.isEmpty || NativeIO.hashFile(path) == sha else{throw StudioError("Файл модели повреждён: "+path.lastPathComponent)}}
    public func setup()throws {
        _=try ensure(design:false);_=try ensure(design:true)
        NativeIO.stage("Проверка встроенных словарей и нативных движков")
        let dictionary=resources.appendingPathComponent("resources/russian_accents_full.sacc")
        guard try NativeIO.hashFile(dictionary) == "a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27" else{throw StudioError("Повреждён встроенный словарь")}
    }
}
