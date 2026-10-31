import { Effect, Schema } from "effect"
import { poll } from "./poll.js"

/** The entity handle does not exist. */
export class EntityNotFound extends Schema.TaggedError<EntityNotFound>()("EntityNotFound", {
  entity: Schema.Number
}) {}

/** Network control or a network id did not resolve in time. */
export class EntityTimeout extends Schema.TaggedError<EntityTimeout>()("EntityTimeout", {
  operation: Schema.Literals(["requestControl", "fromNetId"]),
  id: Schema.Number,
  timeoutMs: Schema.Number
}) {}

export interface WaitOptions {
  /** Milliseconds before failing with `EntityTimeout`. Defaults to 5 000. */
  readonly timeout?: number | undefined
  /** Milliseconds between checks. Defaults to 0 (every tick). */
  readonly interval?: number | undefined
}

const DEFAULT_TIMEOUT_MS = 5_000

/** Requests network control of `entity` until this client has it. */
export const requestControl = (
  entity: number,
  options: WaitOptions = {}
): Effect.Effect<number, EntityNotFound | EntityTimeout> =>
  Effect.suspend((): Effect.Effect<number, EntityNotFound | EntityTimeout> => {
    if (!DoesEntityExist(entity)) return Effect.fail(new EntityNotFound({ entity }))
    const timeoutMs = options.timeout ?? DEFAULT_TIMEOUT_MS
    return poll(
      () => {
        if (NetworkHasControlOfEntity(entity)) return entity
        NetworkRequestControlOfEntity(entity)
        return undefined
      },
      {
        timeoutMs,
        intervalMs: options.interval ?? 0,
        onTimeout: () => new EntityTimeout({ operation: "requestControl", id: entity, timeoutMs })
      }
    )
  })

/** Waits until `netId` exists on this client and returns its local entity handle. */
export const fromNetId = (netId: number, options: WaitOptions = {}): Effect.Effect<number, EntityTimeout> => {
  const timeoutMs = options.timeout ?? DEFAULT_TIMEOUT_MS
  return poll(
    () => {
      if (!NetworkDoesNetworkIdExist(netId)) return undefined
      const entity = NetworkGetEntityFromNetworkId(netId)
      return entity !== 0 && DoesEntityExist(entity) ? entity : undefined
    },
    {
      timeoutMs,
      intervalMs: options.interval ?? 0,
      onTimeout: () => new EntityTimeout({ operation: "fromNetId", id: netId, timeoutMs })
    }
  )
}
