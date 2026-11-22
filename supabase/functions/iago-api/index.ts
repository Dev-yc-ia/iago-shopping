import { handle } from "./handler.ts";

Deno.serve((request) => handle(request));
