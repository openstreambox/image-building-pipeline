// lib/release-preset-ceraui-check.ts — reference check of a release update preset
// with CeraUI's own reader (zod schemas + WHATWG URL), run by lib/release-preset.sh
// when CERALIVE_UPDATE_PRESET_CERAUI_DIR names a CeraUI checkout.
//
//   cd <ceraui>/apps/backend && bun run <this file> <ceraui> <preset dir>
//
// Exit 0 only when CeraUI loads both files and its effective channel URL equals
// the sidecar's channelUrl; prints one JSON line either way.
import { readFileSync } from "node:fs";
import { join } from "node:path";

const [ceraui, dir] = process.argv.slice(2);
if (!ceraui || !dir) {
	console.error("usage: release-preset-ceraui-check.ts <ceraui> <preset dir>");
	process.exit(2);
}
const system = join(ceraui, "apps/backend/src/modules/system");
const settings = await import(join(system, "update-settings.ts"));
const channel = await import(join(system, "update-channel-url.ts"));
const settingsPath = join(dir, "update-settings.json");
try {
	settings.setUpdateSettingsFilePathForTest(settingsPath);
	const loaded = await settings.loadUpdateSettings(settingsPath);
	const effective = await channel.updateChannelUrl();
	const side = JSON.parse(readFileSync(join(dir, "update-image-channel.json"), "utf8"));
	const ok = effective === side.channelUrl;
	console.log(JSON.stringify({ ok, effective, channel: loaded.channel, systemAuto: loaded.systemAuto }));
	process.exit(ok ? 0 : 1);
} catch (error) {
	console.log(JSON.stringify({ ok: false, error: String(error) }));
	process.exit(1);
}
