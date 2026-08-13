import Foundation
import HeadroomCore

func write(_ response: HookResponse) {
    guard let data = try? response.jsonData() else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

do {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    let input = try JSONDecoder().decode(HookInput.self, from: inputData)
    guard HookEvent(rawValue: input.hookEventName) != nil else {
        write(.allow)
        exit(EXIT_SUCCESS)
    }
    let configuration = try ConfigurationStore().load()
    guard configuration.enabled else {
        write(.allow)
        exit(EXIT_SUCCESS)
    }
    let client = try CodexAppServerClient()
    let snapshot = try MeterService(client: client).refresh(coalesceWithin: 2)
    let decision = ReservePolicy.evaluate(snapshot: snapshot, configuration: configuration)
    write(HookPolicy.response(
        for: input.hookEventName,
        decision: decision,
        reservePercent: configuration.reservePercent
    ))
} catch {
    try? StatusStore().save(HeadroomStatus(snapshot: nil, error: error.localizedDescription))
    write(.allow)
}
