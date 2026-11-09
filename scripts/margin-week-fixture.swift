// Deterministic week-view test image with independent expected events. Not an Outlook capture.
import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let events: [[String: Any]] = [
 ["title":"Standup","start":"2026-10-05T09:00:00-07:00","duration_minutes":30,"all_day":false,"location":""],
 ["title":"Design review","start":"2026-10-05T10:00:00-07:00","duration_minutes":60,"all_day":false,"location":""],
 ["title":"Client call","start":"2026-10-06T09:30:00-07:00","duration_minutes":45,"all_day":false,"location":""],
 ["title":"Budget sync","start":"2026-10-06T09:45:00-07:00","duration_minutes":45,"all_day":false,"location":""],
 ["title":"Team offsite","start":"2026-10-07","duration_minutes":1440,"all_day":true,"location":""],
 ["title":"Standup","start":"2026-10-07T09:00:00-07:00","duration_minutes":30,"all_day":false,"location":""],
 ["title":"Focus block","start":"2026-10-08T13:00:00-07:00","duration_minutes":120,"all_day":false,"location":""],
 ["title":"Weekly review","start":"2026-10-09T16:00:00-07:00","duration_minutes":60,"all_day":false,"location":""]]
let ambiguous = CommandLine.arguments.contains("--ambiguous")
let width=1440, height=1160
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
let transform=NSAffineTransform(); transform.translateX(by:0,yBy:CGFloat(height));transform.scaleX(by:1,yBy:-1);transform.concat()
func box(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:NSColor){color.setFill();NSBezierPath(rect:NSRect(x:x,y:y,width:w,height:h)).fill()}
func text(_ s:String,_ x:Double,_ y:Double,_ size:Double=18,_ color:NSColor = .black){
 let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color]
 // AppKit text needs a flipped context to remain upright.
 NSGraphicsContext.saveGraphicsState(); let t=NSAffineTransform();t.translateX(by:x,yBy:y+size+5);t.scaleX(by:1,yBy:-1);t.concat();(s as NSString).draw(at:.zero,withAttributes:attrs);NSGraphicsContext.restoreGraphicsState()
}
box(0,0,1440,1160,.white);box(0,0,1440,58,NSColor(calibratedRed:0,green:0.36,blue:0.68,alpha:1))
text("Calendar · Week",24,14,24,.white);text(ambiguous ? "October 5–9" : "October 5–9, 2026",100,75,28);if !ambiguous {text("Time zone: America/Los_Angeles (UTC−07:00)",750,81,19)}
let days=["Monday 5","Tuesday 6","Wednesday 7","Thursday 8","Friday 9"]
for i in 0..<5 {text(days[i],106+Double(i)*264,133,21)}
text("All day",12,181,16)
for i in 0...5 {box(96+Double(i)*264,125,1,1000,NSColor.lightGray)}
for hour in 9...18 {let y=240+Double(hour-9)*96;box(96,y,1320,1,.lightGray);if hour<18{text(String(format:"%02d:00",hour),18,y-10,16)}}
for (i,e) in events.enumerated(){
 let date=e["start"] as! String;let day=Int(date.dropFirst(8).prefix(2))!-5
 let all=e["all_day"] as! Bool;let mins=e["duration_minutes"] as! Int
 var x=102+Double(day)*264;var w=251.0;var y=176.0;var h=38.0
 var label="All day"
 if !all {
  let hh=Int(date.dropFirst(11).prefix(2))!,mm=Int(date.dropFirst(14).prefix(2))!
  y=240+Double((hh-9)*60+mm)*1.6;h=Double(mins)*1.6-2
  label=String(format:"%02d:%02d–%02d:%02d",hh,mm,(hh*60+mm+mins)/60,(hh*60+mm+mins)%60)
  if day==1 {w=122;if i==3{x+=129}}
 }
 box(x,y,w,h,NSColor(calibratedRed:0.83,green:0.91,blue:0.99,alpha:1));box(x,y,4,h,NSColor.systemBlue)
 text(e["title"] as! String,x+8,y+3,day==1 ? 16:18);if h>39{text(label,x+8,y+25,14)}
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("week.png"))
var expected:[String:Any]=["fixture":"Synthetic Outlook-style week grid, not a user screenshot","request":"Create all the visible events from this week calendar screenshot, preserving their titles, dates, times and durations.","events":events]
if ambiguous { expected["expect_blocked"] = true; expected["uncertainties"] = ["Year and timezone are not shown"] }
try JSONSerialization.data(withJSONObject:expected,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("week.json"))
