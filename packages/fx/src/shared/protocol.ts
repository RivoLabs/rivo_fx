/**
 * Wire shapes and event names from docs/PROTOCOL.md (v1).
 * Keep this file in lockstep with the Lua implementation.
 */
import type { WireError } from "./errors.js"

export const reqEvent = (resource: string): string => `__rfx:${resource}:req`
export const resEvent = (resource: string): string => `__rfx:${resource}:res`
export const cancelEvent = (resource: string): string => `__rfx:${resource}:cancel`

/** Event every SecurityEvent is mirrored to with `TriggerEvent(name, event, resourceName)`. */
export const SECURITY_EVENT = "rivo_fx:security"

export interface RpcRequest {
  readonly id: number
  readonly name: string
  readonly from: string
  readonly input: unknown
  /** W3C traceparent of the caller's span, when it has one. */
  readonly trace?: string
}

export type RpcResponse =
  | { readonly id: number; readonly ok: true; readonly value: unknown }
  | { readonly id: number; readonly ok: false; readonly error: WireError }

export interface RpcCancel {
  readonly id: number
  readonly from: string
}

const isRecord = (u: unknown): u is Record<string, unknown> => typeof u === "object" && u !== null && !Array.isArray(u)
const isId = (u: unknown): u is number => typeof u === "number" && Number.isInteger(u)
const isName = (u: unknown): u is string => typeof u === "string" && u.length > 0

export const parseRequest = (u: unknown): RpcRequest | undefined => {
  if (!(isRecord(u) && isId(u["id"]) && isName(u["name"]) && isName(u["from"]))) return undefined
  const trace = u["trace"]
  return typeof trace === "string" && trace.length <= 64
    ? { id: u["id"], name: u["name"], from: u["from"], input: u["input"], trace }
    : { id: u["id"], name: u["name"], from: u["from"], input: u["input"] }
}

const TRACEPARENT = /^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$/

/** Trace and span ids from a W3C traceparent, or undefined when it is not one. */
export const parseTraceparent = (s: string | undefined): { traceId: string; spanId: string } | undefined => {
  const m = s === undefined ? null : TRACEPARENT.exec(s.toLowerCase())
  if (m === null || m[1] === "ff" || /^0+$/.test(m[2]!) || /^0+$/.test(m[3]!)) return undefined
  return { traceId: m[2]!, spanId: m[3]! }
}

/** A W3C traceparent for these ids, or undefined when they are not W3C shaped. */
export const formatTraceparent = (traceId: string, spanId: string): string | undefined => {
  const s = `00-${traceId}-${spanId}-01`
  return parseTraceparent(s) === undefined ? undefined : s
}

export const parseResponse = (u: unknown): RpcResponse | undefined => {
  if (!isRecord(u) || !isId(u["id"]) || typeof u["ok"] !== "boolean") return undefined
  return u["ok"]
    ? { id: u["id"], ok: true, value: u["value"] }
    : { id: u["id"], ok: false, error: u["error"] as WireError }
}

export const parseCancel = (u: unknown): RpcCancel | undefined =>
  isRecord(u) && isId(u["id"]) && isName(u["from"]) ? { id: u["id"], from: u["from"] } : undefined
