import { Schema } from "effect"

/** Thrown by the server, rebuilt on the client by `Rpc.call(..., { errors: NotEnoughMoney })`. */
export class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

export const Deposit = Schema.Struct({
  amount: Schema.Int.check(Schema.isGreaterThan(0))
})

export const Withdraw = Schema.Struct({
  amount: Schema.Int.check(Schema.isGreaterThan(0))
})
