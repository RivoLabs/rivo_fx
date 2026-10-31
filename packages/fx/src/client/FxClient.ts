import { Layer } from "effect"
import * as Config from "../shared/Config.js"
import * as Logger from "../shared/Logger.js"
import { RpcClient } from "./Rpc.js"

/** Every service a client resource needs. */
export type Services = RpcClient

/** The RPC caller and host, the convar `ConfigProvider` and the FiveM logger, in one layer. */
export const layer: Layer.Layer<Services> = RpcClient.layer.pipe(
  Layer.provideMerge(Layer.mergeAll(Config.layer(), Logger.layer))
)
