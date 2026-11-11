import { z } from "zod";

/** Strip C0/C1 controls and keep at most 128 code points, as the terminal would truncate. */
export function sanitizeText(value: string, replace: string): string {
  let result = "";
  let count = 0;
  for (const char of value) {
    if (/[\x00-\x1f\x7f-\x9f]/.test(char)) {
      if (!replace) continue;
      result += replace;
    } else result += char;
    if (++count === 128) break;
  }
  return result;
}

/** A strict object: unknown fields are an error, never silently dropped into the wire document. */
function strict<T extends z.core.$ZodLooseShape>(shape: T) {
  return z.strictObject(shape, {
    error: (issue) => (issue.code === "unrecognized_keys" ? "unknown field" : "expected an object"),
  });
}

export const StatusSchema = strict({
  text: z.string({ error: "text must be a string" }).transform((value) => sanitizeText(value, "")),
  tone: z.enum(["info", "warn", "error"], { error: "invalid status tone" }),
  expires: z.int({ error: "expires must be Unix milliseconds" }).min(0, { error: "expires must be Unix milliseconds" }).optional(),
}).readonly();

export const MarkSchema = z.union([z.enum(["idle", "busy", "error"]), z.literal([0, 1, 2, 3])], { error: "invalid chrome mark" });

const progressError = "progress must be 0..1 or indeterminate";
export const ProgressSchema = z.union(
  [z.number().min(0, { error: progressError }).max(1, { error: progressError }), z.literal("indeterminate")],
  { error: progressError },
);

const edge = z.int({ error: "sprite edges must be 1..32" })
  .min(1, { error: "sprite edges must be 1..32" })
  .max(32, { error: "sprite edges must be 1..32" });

function isStandardBase64Rgba(frame: string, length: number): boolean {
  let decoded: string;
  try {
    decoded = atob(frame);
  } catch {
    return false;
  }
  return decoded.length === length && btoa(decoded) === frame;
}

/** Inline RGBA8 sprite: 1..4 standard base64 frames of exactly w*h*4 bytes. */
export const SpriteSchema = strict({
  w: edge,
  h: edge,
  frames: z.array(z.string({ error: "sprite frame does not match dimensions" }), { error: "sprite needs 1..4 frames" })
    .min(1, { error: "sprite needs 1..4 frames" })
    .max(4, { error: "sprite needs 1..4 frames" })
    .readonly(),
}).superRefine((sprite, context) => {
  const length = sprite.w * sprite.h * 4;
  for (const frame of sprite.frames) {
    if (frame.length !== 4 * Math.ceil(length / 3)) {
      context.addIssue({ code: "custom", message: "sprite frame does not match dimensions" });
      return;
    }
    if (!isStandardBase64Rgba(frame, length)) {
      context.addIssue({ code: "custom", message: "sprite frame must be standard base64 RGBA" });
      return;
    }
  }
}).readonly();

/** A full OSC 771 chrome document. */
export const ChromeSchema = strict({
  status: StatusSchema.optional(),
  mark: MarkSchema.optional(),
  progress: ProgressSchema.optional(),
  sprite: SpriteSchema.optional(),
}).readonly();

/** A field-preserving update: `null` removes a field, `undefined` keeps it. */
export const ChromePatchSchema = strict({
  status: StatusSchema.nullable().optional(),
  mark: MarkSchema.nullable().optional(),
  progress: ProgressSchema.nullable().optional(),
  sprite: SpriteSchema.nullable().optional(),
}).readonly();

export const SpriteAnimationSchema = strict({
  sprite: z.unknown(),
  intervalMs: z.int({ error: "sprite interval must be 50..60000 ms" })
    .min(50, { error: "sprite interval must be 50..60000 ms" })
    .max(60_000, { error: "sprite interval must be 50..60000 ms" }),
});

/** Host responses are objects; extra fields are allowed and ignored. */
export const HostResponseSchema = z.looseObject({}, { error: "invalid host response" });

export const HostIdentifierSchema = z.int({ error: "invalid host identifier" }).min(0, { error: "invalid host identifier" });

export const ShellStateSchema = z.looseObject({
  shell: z.looseObject({ ready: z.literal(true), cwd: z.string().nullable() }),
}, { error: "integrated shell prompt required" });

export const DispatchReceiptSchema = z.looseObject({
  accepted: z.literal(true),
  completion_untrusted: z.literal(true),
  after_command_id: z.unknown(),
}, { error: "invalid dispatch receipt" });

/** Parse with a schema and report the first problem as a RangeError, the SDK's validation error type. */
export function parse<T extends z.ZodType>(schema: T, value: unknown, fallback?: string): z.output<T> {
  const result = schema.safeParse(value);
  if (result.success) return result.data;
  throw new RangeError(fallback ?? result.error.issues[0]?.message ?? "invalid value", { cause: result.error });
}
