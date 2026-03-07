// daylight-notify — Email collection endpoint for Daylight Mirror update notifications.
//
// POST /subscribe { email, version, source? }
// Stores email + app version + install source (stripe/github/unknown) in D1.
// Deduplicates by email (upserts on conflict).

interface Env {
  DB: D1Database;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // CORS headers for preflight and responses
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: cors });
    }

    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/subscribe") {
      try {
        const body = await request.json<{
          email: string;
          version?: string;
          source?: string;
        }>();

        const email = body.email?.trim().toLowerCase();
        if (!email || !email.includes("@")) {
          return Response.json(
            { error: "invalid email" },
            { status: 400, headers: cors }
          );
        }

        const version = body.version || "unknown";
        const source = body.source || "unknown";

        await env.DB.prepare(
          `INSERT INTO subscribers (email, version, source, created_at)
           VALUES (?, ?, ?, datetime('now'))
           ON CONFLICT(email) DO UPDATE SET
             version = excluded.version,
             source = excluded.source,
             updated_at = datetime('now')`
        )
          .bind(email, version, source)
          .run();

        return Response.json({ ok: true }, { headers: cors });
      } catch (e) {
        return Response.json(
          { error: "server error" },
          { status: 500, headers: cors }
        );
      }
    }

    return Response.json(
      { error: "not found" },
      { status: 404, headers: cors }
    );
  },
};
