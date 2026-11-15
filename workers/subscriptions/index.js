import {reply} from "./auth.js";

const formats = {
  linux: ["linux.json", "application/json"],
  "sing-box": ["sing-box.json", "application/json"],
  shadowrocket: ["shadowrocket.conf", "text/plain; charset=utf-8"],
  "shadowrocket-subscribe": ["shadowrocket.txt", "text/plain; charset=utf-8"],
  "shadowrocket-config": ["shadowrocket-config.conf", "text/plain; charset=utf-8"],
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Cloudflare selects the Worker by route; the final segment identifies the subscription.
    const path = url.pathname.slice(url.pathname.lastIndexOf("/"));
    if (request.method !== "GET" || url.protocol !== "https:" ||
        !/^\/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(path)) {
      return reply(null, 404);
    }
    let client = url.searchParams.get("client")?.toLowerCase();
    if (client === undefined) {
      const agent = request.headers.get("User-Agent") ?? "";
      if (/shadowrocket\//i.test(agent)) client = "shadowrocket";
      else if (/sing-box|\b(?:sfa|sfi|sfm|sft)\//i.test(agent)) client = "sing-box";
    }
    if (!Object.hasOwn(formats, client)) {
      return reply("Specify ?client=linux, sing-box, shadowrocket, shadowrocket-subscribe or shadowrocket-config\n", 400, "text/plain; charset=utf-8");
    }
    const [filename, contentType] = formats[client];
    const asset = await env.ASSETS.fetch(new Request(new URL(`${path}/${filename}`, url.origin)));
    if (!asset.ok) return reply(null, 404);
    const response = reply(asset.body, 200, contentType);
    response.headers.set("Vary", "User-Agent");
    if (client === "shadowrocket" || client === "shadowrocket-config") {
      const metadata = await env.ASSETS.fetch(new Request(new URL(`${path}/metadata.json`, url.origin)));
      if (!metadata.ok) return reply(null, 404);
      const {id, name} = await metadata.json();
      const filename = encodeURIComponent(`${name}.conf`).replace(/['()*]/g,
        character => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
      response.headers.set("Content-Disposition", `attachment; filename="${id}.conf"; filename*=UTF-8''${filename}`);
    }
    return response;
  },
};
