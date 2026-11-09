import Foundation
struct ToolArgumentError: LocalizedError { let message: String; var errorDescription: String? { message } }
@main struct Smoke {
 static func main() async throws {
  let image = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
  let answer = try await MarginImageReader.answer(image:image, question:"What is the total including tax? Do not save anything.", base:"http://127.0.0.1:11434", planner:"margin-lora-pilot:final") { print($0) }
  print(answer)
 }
}
