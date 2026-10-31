/** Small helpers over FiveM globals that exist on both the server and the client. */

/** `GetCurrentResourceName()`, read at call time so tests can mock it. */
export const resourceName = (): string => GetCurrentResourceName()

/** True inside a server script. */
export const isServer = (): boolean => IsDuplicityVersion()
