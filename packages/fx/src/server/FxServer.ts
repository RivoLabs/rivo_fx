import { Layer } from "effect"
import * as Config from "../shared/Config.js"
import * as Logger from "../shared/Logger.js"
import { PlayerScopes } from "./PlayerScope.js"
import { RateLimiter } from "./RateLimiter.js"
import { RpcServer } from "./Rpc.js"
import { SecurityEvents } from "./SecurityEvents.js"

/** Every service a server resource needs. */
export type Services = SecurityEvents | RateLimiter | RpcServer | PlayerScopes

/**
 * SecurityEvents, rate limiting, the RPC host and caller, player scopes, the
 * convar `ConfigProvider` and the FiveM logger, in one layer.
 *
 * ```ts
 * FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
 * ```
 */
export const layer: Layer.Layer<Services> = Layer.mergeAll(RpcServer.layer, PlayerScopes.layer).pipe(
  Layer.provideMerge(Layer.mergeAll(SecurityEvents.layer, RateLimiter.layer)),
  Layer.provideMerge(Layer.mergeAll(Config.layer(), Logger.layer))
)
