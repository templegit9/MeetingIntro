  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let journalURL = directory.appendingPathComponent("active.json")
  let journal = MarginRunJournal(url: journalURL)
  try journal.start(goal: "Save a diagram", messages: [["role": "user", "content": "Save a diagram"]])
  let preview = ProposedAction(kind: .change, title: "Save", details: ["diagram.png"], run: { _ in "Saved" })
  let sourceID = UUID()
  try journal.pause(call: .init(name: "save", arguments: ["name": "diagram.png"]), action: preview, messages: [["role": "assistant", "content": "proposal"]], sourceAttachmentID: sourceID)
  let restored = MarginRunJournal(url: journalURL)
  check(restored.current?.state == "awaiting confirmation" && restored.current?.goal == "Save a diagram", "restart preserves unapproved goal and arguments")
  check(restored.current?.pending?.sourceAttachmentID == sourceID, "calendar source binding survives restart")
  try restored.executionStarted(choice: nil, signature: preview.approvalSignature(choice: nil))
  let interrupted = MarginRunJournal(url: journalURL)
  check(interrupted.current?.state == "uncertain", "crash during write becomes uncertain")
  do { try interrupted.executionStarted(choice: nil, signature: Data()); fatalError("replayed uncertain write") }
  catch { check(true, "uncertain write cannot execute again") }
  try journal.executionStarted(choice: nil, signature: preview.approvalSignature(choice: nil))
  try journal.receipt("Saved /granted/diagram.png", success: true)
  let receipt = try journal.transcript().last?["content"] as? String ?? ""
  let decodedReceipt = try JSONSerialization.jsonObject(with: Data(receipt.utf8)) as! [String: Any]
  check(decodedReceipt["status"] as? String == "executed" && decodedReceipt["result"] as? String == "Saved /granted/diagram.png", "execution receipt returns to model transcript")
  check(journal.current?.pending == nil, "execution consumes pending approval")
  let changed = ProposedAction(kind: .change, title: "Save", details: ["different.png"], run: { _ in "Saved" })
  check(try preview.approvalSignature(choice: nil) != changed.approvalSignature(choice: nil), "approval binds displayed target")
  for _ in 0..<24 { try journal.spendRound() }
  do { try journal.spendRound(); fatalError("unbounded resumed task") } catch { check(true, "resumes share persistent call budget") }
  let corruptURL = directory.appendingPathComponent("corrupt.json")
  try Data("broken".utf8).write(to: corruptURL)
  let corrupt = MarginRunJournal(url: corruptURL)
  do { try corrupt.start(goal: "replace", messages: []); fatalError("overwrote corrupt journal") } catch { check(true, "corrupt journal fails closed") }
  var paused = false; var rendered = false
  do {
   try await MarginToolLoop.run(messages: [], request: { _ in reply("save") }, prepare: { _ in preview }, pause: { _, _, _ in
    paused = true; throw NSError(domain: "disk full", code: 1)
   }, present: { _ in rendered = true }, answer: { _ in })
   fatalError("lost persistence error")
  } catch { check(paused && !rendered, "failed persistence cannot publish executable proposal") }
  try interrupted.reconcile(wasExecuted: false)
  check(interrupted.current?.state == "awaiting confirmation", "human no-effect reconciliation requires new preview")
  do {
   try journal.pause(call: .init(name: "save", arguments: ["name": "diagram.png"]), action: preview, messages: [])
   fatalError("duplicate operation proposed")
  } catch { check(true, "completed operation cannot repeat within same task") }
  try journal.mark("interrupted")
  let oldID = journal.current!.id
  try journal.start(goal: "Another task", messages: [])
  check(try journal.recoverableRecords().contains(where: { $0.id == oldID }), "starting another goal keeps interrupted task discoverable")
  try journal.activate(oldID)
  check(journal.current?.id == oldID && journal.current?.goal == "Save a diagram", "archived goal can be restored with its original state")
