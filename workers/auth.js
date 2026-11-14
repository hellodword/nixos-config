export async function authorized(request, access, identity) {
  const candidate = request.headers.get("authorization")?.replace(/^Bearer /, "");
  if (!candidate || !access) return false;
  const digest = async value => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const supplied = await digest(candidate);
  const identities = JSON.parse(access);
  for (const token of Object.hasOwn(identities, identity) ? identities[identity] : []) {
    const expected = await digest(token);
    let difference = 0;
    for (let i = 0; i < expected.length; i++) difference |= expected[i] ^ supplied[i];
    if (difference === 0) return true;
  }
  return false;
}

export function reply(body, status = 200, type = "application/json") {
  return new Response(body, {status, headers: {
    "Content-Type": type, "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  }});
}
