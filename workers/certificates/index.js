import {authorized, reply} from "./auth.js";

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const node = path.slice(path.lastIndexOf("/") + 1);
    if (request.method !== "GET" || !/^[a-z][a-z0-9-]*$/.test(node)) return reply(null, 404);
    if (!await authorized(request, env.ACCESS, node)) return reply(null, 401);
    try {
      const response = await fetch(`https://api.porkbun.com/api/json/v3/ssl/retrieve/${encodeURIComponent(env.PORKBUN_DOMAIN)}`, {
        method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({apikey: env.PORKBUN_API_KEY, secretapikey: env.PORKBUN_SECRET_KEY}),
        signal: AbortSignal.timeout(20000),
      });
      if (!response.ok) return reply(null, 502);
      const certificate = await response.json();
      if (certificate.status !== "SUCCESS" || !certificate.certificatechain || !certificate.privatekey) return reply(null, 502);
      return reply(JSON.stringify({certificate: certificate.certificatechain, key: certificate.privatekey}));
    } catch {
      return reply(null, 502);
    }
  },
};
