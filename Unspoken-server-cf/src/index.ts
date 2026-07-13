export { UnspokenServer } from "./server";

export interface Env {
  SERVER: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      // The whole server is one Durable Object instance, mirroring the
      // single-process Python server so room ids stay server-generated.
      const stub = env.SERVER.get(env.SERVER.idFromName("main"));
      return stub.fetch(request);
    }
    const url = new URL(request.url);
    if (url.pathname === "/" && request.method === "GET") {
      return new Response("Unspoken server is running.\n", { status: 200 });
    }
    return new Response("Expected WebSocket upgrade", { status: 426 });
  },
};
