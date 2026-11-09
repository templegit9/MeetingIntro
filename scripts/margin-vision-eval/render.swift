import AppKit
import Foundation
let args = CommandLine.arguments
let specs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
for spec in specs {
 let lines = spec["lines"] as! [String], id = spec["id"] as! String, kind = spec["kind"] as! String
 let size = NSSize(width: 1200, height: 900)
 let image = NSImage(size: size)
 image.lockFocus()
 NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
 func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ sz: CGFloat = 30) {
  (s as NSString).draw(at: NSPoint(x:x,y:900-y-sz-6), withAttributes:[.font:NSFont.systemFont(ofSize:sz),.foregroundColor:NSColor.black])
 }
 if kind == "diagram" {
  text(lines[0],50,35,40)
  let labels = ["Client","API","Queue","Worker","Database"]
  for (i,label) in labels.enumerated() {
   let x=CGFloat(30+i*230)
   NSColor(calibratedRed:0.85,green:0.93,blue:0.9,alpha:1).setFill()
   NSBezierPath(roundedRect:NSRect(x:x,y:560,width:180,height:110),xRadius:12,yRadius:12).fill()
   text(label,x+12,265,26)
   if i < 4 { text("→",x+185,265,32) }
  }
  text("↓ on failure",725,380,28); text("Dead-letter queue",700,470,30)
  if id == "changed" { text("↓",290,380,32); text("Cache",275,470,30) }
 } else if kind == "chart" {
  text(lines[0],50,35,40)
  for (i,v) in [8,3,6].enumerated() {
   let x=CGFloat(130+i*320)
   NSColor.systemBlue.setFill(); NSRect(x:x,y:150,width:160,height:CGFloat(v*60)).fill()
   text(String(v),x+60,900-150-CGFloat(v*60)-50,32)
   text(["January","February","March"][i],x,770,28)
  }
 } else {
  for (i,line) in lines.enumerated() { text(line,50,CGFloat(40+i*70),i==0 ? 36 : 28) }
 }
 image.unlockFocus()
 let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
 try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[2]).appendingPathComponent(id+".png"))
}
