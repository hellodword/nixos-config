function equalDigests(expected, supplied) {
  if (typeof crypto.subtle.timingSafeEqual === "function") {
    return crypto.subtle.timingSafeEqual(expected, supplied);
  }
  if (expected.byteLength !== supplied.byteLength) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i++) difference |= expected[i] ^ supplied[i];
  return difference === 0;
}

export async function authorized(request, access, identity) {
  const match = request.headers.get("authorization")?.match(/^Bearer (\S+)$/);
  if (!match || !access) return false;
  const candidate = match[1];
  const digest = async value => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const supplied = await digest(candidate);
  const identities = JSON.parse(access);
  for (const token of Object.hasOwn(identities, identity) ? identities[identity] : []) {
    const expected = await digest(token);
    if (equalDigests(expected, supplied)) return true;
  }
  return false;
}

export function reply(body, status = 200, type = "application/json") {
  return new Response(body, {status, headers: {
    "Content-Type": type, "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  }});
}
