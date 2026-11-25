// Weather on the website (issue 203, step 5): the saved places as WeatherPlaces.swift seals them, and
// Open-Meteo's forecast read the way OpenMeteoSource.swift reads it. Only the rounded coordinate is sent.

export interface Place { id: string; name: string; region: string; latitude: number; longitude: number; order: number }

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const uuid = (v: unknown): string | null => (typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? v.toLowerCase() : null);

/** The places still saved, in the person's order. A removed place is a marker with no place, and is left out. */
/** A key move can leave two copies of the record: they come together by keeping each place's later change. */
export function parsePlaces(...records: unknown[]): Place[] {
  const entries: Record<string, unknown> = {};
  for (const raw of records) {
    const these = (raw as { entries?: unknown } | null)?.entries;
    if (!these || typeof these !== "object" || Array.isArray(these)) continue;
    for (const [key, value] of Object.entries(these as Record<string, unknown>)) {
      const at = num((value as { changedAt?: unknown } | null)?.changedAt) ?? 0;
      const held = num((entries[key] as { changedAt?: unknown } | undefined)?.changedAt) ?? -Infinity;
      if (at >= held) entries[key] = value;
    }
  }
  const out: Place[] = [];
  for (const [key, value] of Object.entries(entries as Record<string, unknown>)) {
    const e = value as { place?: unknown; order?: unknown } | null;
    const p = e?.place as { id?: unknown; name?: unknown; region?: unknown; coordinate?: { latitude?: unknown; longitude?: unknown } } | undefined;
    const id = uuid(p?.id);
    const lat = num(p?.coordinate?.latitude), lon = num(p?.coordinate?.longitude);
    // The entry's key is the place's own ID; one that names another is never shown.
    if (!p || !id || id !== key.toLowerCase() || lat === null || lon === null || Math.abs(lat) > 90 || Math.abs(lon) > 180) continue;
    out.push({ id, name: str(p.name) || "Place", region: str(p.region), latitude: lat, longitude: lon, order: num(e?.order) ?? 0 });
  }
  return out.sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : 1));
}

/** Two decimal places, about 1 km: what's sent to a weather source. */
export const rough = (v: number): string => (Math.round(v * 100) / 100).toFixed(2);

export function forecastUrl(p: Pick<Place, "latitude" | "longitude">): string {
  const q = new URLSearchParams({
    latitude: rough(p.latitude), longitude: rough(p.longitude),
    current: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day",
    daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
    forecast_days: "10", timezone: "auto", timeformat: "unixtime",
  });
  return `https://api.open-meteo.com/v1/forecast?${q}`;
}

export interface Day { date: number; high: number; low: number; code: number; chance: number }
export interface Forecast { timezone: string; temperature: number; feelsLike: number; humidity: number; wind: number; code: number; isDay: boolean; days: Day[] }

export function parseForecast(raw: unknown): Forecast | null {
  const o = raw as { timezone?: unknown; current?: Record<string, unknown>; daily?: Record<string, unknown[]> } | null;
  const c = o?.current, d = o?.daily;
  const temperature = num(c?.temperature_2m);
  if (!o || !c || !d || temperature === null || !Array.isArray(d.time)) return null;
  const days: Day[] = [];
  d.time.forEach((t, i) => {
    const high = num(d.temperature_2m_max?.[i]), low = num(d.temperature_2m_min?.[i]), date = num(t);
    if (high === null || low === null || date === null) return;
    days.push({ date: date * 1000, high, low, code: num(d.weather_code?.[i]) ?? 3, chance: num(d.precipitation_probability_max?.[i]) ?? 0 });
  });
  return {
    timezone: str(o.timezone) || "UTC", temperature, feelsLike: num(c.apparent_temperature) ?? temperature,
    humidity: num(c.relative_humidity_2m) ?? 0, wind: num(c.wind_speed_10m) ?? 0, code: num(c.weather_code) ?? 3, isDay: c.is_day !== 0, days,
  };
}

/** WMO weather codes, as WeatherCondition.swift names them. */
export function conditionName(code: number): string {
  if (code === 0) return "Clear";
  if (code === 1) return "Mostly clear";
  if (code === 2) return "Partly cloudy";
  if (code === 45 || code === 48) return "Fog";
  if ([51, 53, 55].includes(code)) return "Drizzle";
  if ([56, 57, 66, 67].includes(code)) return "Freezing rain";
  if ([61, 63, 80, 81].includes(code)) return "Rain";
  if (code === 65 || code === 82) return "Heavy rain";
  if ([71, 73, 77, 85].includes(code)) return "Snow";
  if (code === 75 || code === 86) return "Heavy snow";
  if ([95, 96, 99].includes(code)) return "Thunderstorms";
  return "Cloudy";
}

/** °F where the browser's region uses it, as WeatherUnits.swift chooses. */
export const usesFahrenheit = (locale: string): boolean => /-(US|LR|MM|BS|BZ|KY|PW)\b/.test(locale);
export const temp = (celsius: number, fahrenheit: boolean): string => {
  const v = Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius);
  return `${v === 0 ? 0 : v}°`;
};
export const speed = (kmh: number, fahrenheit: boolean): string => (fahrenheit ? `${Math.round(kmh / 1.609344)} mph` : `${Math.round(kmh)} km/h`);
