// Node globals some crypto dependencies expect in the browser.
import { Buffer } from "buffer";
globalThis.Buffer ??= Buffer;
globalThis.process ??= { env: {}, browser: true, version: "", versions: {} };
