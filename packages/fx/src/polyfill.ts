/**
 * `@rivolabs/fx/polyfill`: UTF-8 `TextEncoder` and `TextDecoder` for FiveM's client
 * JS runtime, which has neither. `effect` creates both when it loads, so a
 * client bundle without them fails with "TextEncoder is not defined".
 *
 * Import it first in every client entry, before `effect`:
 *
 * ```ts
 * import "@rivolabs/fx/polyfill"
 * import { Effect } from "effect"
 * ```
 *
 * It does nothing where the globals already exist (servers, browsers, Node).
 */

class Utf8Encoder {
  readonly encoding = "utf-8"

  encode(input = ""): Uint8Array {
    const out: number[] = []
    for (let i = 0; i < input.length; i++) {
      let c = input.charCodeAt(i)
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < input.length) {
        const next = input.charCodeAt(i + 1)
        if (next >= 0xdc00 && next <= 0xdfff) {
          c = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00)
          i++
        }
      }
      if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd // lone surrogate
      if (c < 0x80) out.push(c)
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    }
    return new Uint8Array(out)
  }

  encodeInto(input: string, dest: Uint8Array): { read: number; written: number } {
    const bytes = this.encode(input)
    const written = Math.min(bytes.length, dest.length)
    dest.set(bytes.subarray(0, written))
    return { read: written === bytes.length ? input.length : 0, written }
  }
}

class Utf8Decoder {
  readonly encoding = "utf-8"

  decode(input?: ArrayBuffer | ArrayBufferView): string {
    if (input === undefined) return ""
    const bytes = input instanceof ArrayBuffer
      ? new Uint8Array(input)
      : new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
    let out = ""
    let i = 0
    while (i < bytes.length) {
      const b = bytes[i++]!
      let c: number
      if (b < 0x80) c = b
      else if (b >= 0xc0 && b < 0xe0 && i < bytes.length) c = ((b & 31) << 6) | (bytes[i++]! & 63)
      else if (b >= 0xe0 && b < 0xf0 && i + 1 < bytes.length) {
        c = ((b & 15) << 12) | ((bytes[i]! & 63) << 6) | (bytes[i + 1]! & 63)
        i += 2
      } else if (b >= 0xf0 && i + 2 < bytes.length) {
        c = ((b & 7) << 18) | ((bytes[i]! & 63) << 12) | ((bytes[i + 1]! & 63) << 6) | (bytes[i + 2]! & 63)
        i += 3
      } else c = 0xfffd
      if (c >= 0x10000) {
        c -= 0x10000
        out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023))
      } else out += String.fromCharCode(c)
    }
    return out
  }
}

const g = globalThis as Record<string, unknown>
if (typeof g["TextEncoder"] === "undefined") g["TextEncoder"] = Utf8Encoder
if (typeof g["TextDecoder"] === "undefined") g["TextDecoder"] = Utf8Decoder

export {}
