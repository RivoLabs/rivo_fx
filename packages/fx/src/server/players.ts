import { Effect } from "effect"

/** Listens for `playerDropped`. The callback gets the dropped player's id. Returns a remover. */
export const onPlayerDropped = (callback: (player: number, reason: string) => void): (() => void) => {
  const listener = (reason: string) => {
    const player = Number(source)
    if (Number.isInteger(player) && player > 0) callback(player, reason)
  }
  on("playerDropped", listener)
  return () => removeEventListener("playerDropped", listener)
}

/** Runs `effect`, interrupting it if `player` drops before it finishes. */
export const interruptOnDrop = <A, E, R>(player: number, effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  Effect.raceFirst(
    effect,
    Effect.callback<never>((resume) => {
      const off = onPlayerDropped((dropped) => {
        if (dropped === player) resume(Effect.interrupt)
      })
      return Effect.sync(off)
    })
  )
