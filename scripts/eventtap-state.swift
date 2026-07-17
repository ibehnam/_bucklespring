#!/usr/bin/env swift

import CoreGraphics
import Foundation

let requestedPID: Int32?
if CommandLine.arguments.count == 1 {
    requestedPID = nil
} else {
    guard CommandLine.arguments.count == 2,
          let pid = Int32(CommandLine.arguments[1]) else {
        fputs("usage: eventtap-state.swift [pid]\n", stderr)
        exit(2)
    }
    requestedPID = pid
}
var count: UInt32 = 0
let capacity: UInt32 = 128
let taps = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
defer { taps.deallocate() }

let error = CGGetEventTapList(capacity, taps, &count)
guard error == .success else {
    fputs("CGGetEventTapList error: \(error)\n", stderr)
    exit(1)
}

var found = false
var enabled = true
for index in 0..<Int(count) {
    let tap = taps[index]
    if let requestedPID, tap.tappingProcess != requestedPID {
        continue
    }

    found = true
    enabled = enabled && tap.enabled
    print("tap id=\(tap.eventTapID) pid=\(tap.tappingProcess) " +
          "tapped=\(tap.processBeingTapped) enabled=\(tap.enabled) " +
          "options=\(tap.options.rawValue) " +
          "mask=0x\(String(tap.eventsOfInterest, radix: 16)) " +
          "avgLatUs=\(tap.avgUsecLatency) maxLatUs=\(tap.maxUsecLatency)")
}

if requestedPID != nil && (!found || !enabled) {
    exit(1)
}
