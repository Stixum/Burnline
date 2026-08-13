#!/usr/bin/env swift
import AppKit
import Foundation

// Draws the DMG window background: the instruction line and the arrow between
// where the two icons sit. The icons themselves are placed by AppleScript in
// release.sh; this only paints what is behind them, so the two sets of
// coordinates must agree.
//
// Same approach as Tools/make-icon.swift — drawn in code rather than checked in
// as a binary, so it stays editable and reviewable in a diff.

let width = 600.0
// 45pt taller than the 400pt the layout is designed for. Finder's status bar
// cannot be reliably hidden from AppleScript on current macOS — `statusbar
// visible` does not stick across the close/open that applies the background —
// so it eats ~25pt of the content area. Overdrawing means that strip has dark
// behind it rather than white. Every position below is measured FROM THE TOP,
// so the extra height only ever adds background at the bottom.
let height = 445.0

// Matches Theme.swift. The DMG window is the first thing anyone sees, and a
// default grey one next to a hardcoded-dark app looks like two products.
let background = NSColor(red: 10 / 255, green: 10 / 255, blue: 15 / 255, alpha: 1)
let accent = NSColor(red: 124 / 255, green: 92 / 255, blue: 255 / 255, alpha: 1)
let textPrimary = NSColor.white
let textMuted = NSColor(red: 168 / 255, green: 168 / 255, blue: 188 / 255, alpha: 1)

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

background.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, centerX: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    if tracking != 0 { attributes[.kern] = tracking }
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let bounds = attributed.size()
    attributed.draw(at: NSPoint(x: centerX - bounds.width / 2, y: y))
}

// Title block, top of the window.
draw("BURNLINE", size: 11, weight: .bold, color: textMuted,
     centerX: width / 2, y: height - 62, tracking: 2.2)
draw("Drag Burnline into Applications to install", size: 17, weight: .semibold,
     color: textPrimary, centerX: width / 2, y: height - 96)

// Icons are placed by AppleScript at {150,190} and {450,190}, and Finder
// positions by icon CENTRE, measured from the window top. Cocoa draws from the
// bottom, so the centre line is height - 190. The arrow must sit exactly there
// or it reads as unrelated to the icons.
let arrowY = height - 190
let arrowStart = 232.0
let arrowEnd = 368.0

accent.setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 3
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: arrowStart, y: arrowY))
shaft.line(to: NSPoint(x: arrowEnd - 12, y: arrowY))
shaft.stroke()

accent.setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEnd, y: arrowY))
head.line(to: NSPoint(x: arrowEnd - 16, y: arrowY + 9))
head.line(to: NSPoint(x: arrowEnd - 16, y: arrowY - 9))
head.close()
head.fill()

// No icon labels drawn here: Finder renders the filename under each icon
// itself, so anything painted there would be a duplicate sitting slightly off.

// The setup step, stated before first launch rather than only inside the app.
// Someone who reads it here is not surprised by the window that opens later.
draw("After installing, open Burnline and choose Set up automatically",
     size: 12, weight: .regular, color: textMuted, centerX: width / 2, y: height - 328)
draw("so Claude Code reports usage as you work.",
     size: 12, weight: .regular, color: textMuted, centerX: width / 2, y: height - 348)
draw("Burnline asks macOS for no permissions of its own.",
     size: 11, weight: .regular, color: textMuted, centerX: width / 2, y: height - 372)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render background\n".utf8))
    exit(1)
}

let out = URL(fileURLWithPath: "build/dmg-background.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try png.write(to: out)
print("wrote \(out.path)")
