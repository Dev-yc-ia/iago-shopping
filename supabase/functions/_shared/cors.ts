const PRODUCTION_ORIGINS = new Set([
  "https://ia-go.api.br",
  "https://www.ia-go.api.br",
]);

const LOCAL_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/;

export function isAllowedOrigin(origin: string | null): boolean {
  if (!origin) return false;
  return PRODUCTION_ORIGINS.has(origin) || LOCAL_ORIGIN.test(origin);
}

export function corsHeaders(request: Request): HeadersInit {
  const origin = request.headers.get("origin");
  const headers: Record<string, string> = {
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-max-age": "86400",
    vary: "Origin",
  };

  if (isAllowedOrigin(origin)) {
    headers["access-control-allow-origin"] = origin as string;
  }

  return headers;
}

export function optionsResponse(request: Request): Response {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(request),
  });
}
