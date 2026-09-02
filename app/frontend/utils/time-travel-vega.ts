import type { VisualizationSpec } from "vega-embed";
import type { XAxisKey } from "../types/bubble-chart.type";
import type {
  TimeTravelRow,
  TimeTravelSnapshot,
} from "../types/time-travel.type";
import type { AxisOption } from "../components/axis-controls.component";
import { MAX_CIRCLE_RADIUS } from "./bubble-chart-vega";
import { SINGLE_COLOR_PALETTE, xAxisTitleForKey } from "./bubble-chart-utils";

export const MIN_TIME_TRAVEL_YEAR = 2015;
export const MAX_TIME_TRAVEL_ARTICLES = 8;
export const PANEL_HEIGHT = 480;

export const TIME_TRAVEL_X_AXIS_KEYS: XAxisKey[] = [
  "title",
  "publication_date",
  "article_size",
  "lead_section_size",
  "talk_size",
];

export const TIME_TRAVEL_X_AXIS_OPTIONS: AxisOption<XAxisKey>[] = [
  { value: "title", label: "Article title (A-Z)" },
  { value: "publication_date", label: "Creation date (Old-New)" },
  { value: "article_size", label: "Article size (Small-Large)" },
  { value: "lead_section_size", label: "Lead section size (Small-Large)" },
  { value: "talk_size", label: "Discussion page size (Small-Large)" },
];

const SIZE_RANGES = {
  talk_size: [50, 1500] as [number, number],
  other_article_size: [20, 600] as [number, number],
  lead_section_size: [30, 800] as [number, number],
  article_size: [20, 600] as [number, number],
};

type SizeField = keyof typeof SIZE_RANGES;

export type SharedScales = {
  sizeDomains: Record<SizeField, [number, number]>;
  yDomain: { min: number; max: number };
};

// Both panels must share every scale, or the same value renders at a different
// height and radius on each side and the comparison is meaningless.
export function computeSharedScales(rows: TimeTravelRow[]): SharedScales {
  const present = rows.filter((row) => row.exists);
  const maxOf = (field: SizeField) =>
    Math.max(1, ...present.map((row) => row[field] ?? 0));
  const views = present
    .map((row) => row.average_daily_views)
    .filter(
      (value): value is number => value !== null && Number.isFinite(value),
    );

  return {
    sizeDomains: {
      talk_size: [0, maxOf("talk_size")],
      other_article_size: [0, maxOf("other_article_size")],
      lead_section_size: [0, maxOf("lead_section_size")],
      article_size: [0, maxOf("article_size")],
    },
    yDomain: {
      min: views.length ? Math.min(...views) : 0,
      max: views.length ? Math.max(...views) : 1000,
    },
  };
}

export function buildTimeTravelRows(
  titles: string[],
  snapshots: Record<string, TimeTravelSnapshot | null>,
  otherSnapshots: Record<string, TimeTravelSnapshot | null>,
  publicationDates: Record<string, string | null>,
): TimeTravelRow[] {
  return titles.map((title, index) => {
    const snapshot = snapshots[title] ?? null;
    return {
      article: title,
      idx: index + 1,
      exists: snapshot !== null,
      publication_date: publicationDates[title] ?? null,
      article_size: snapshot?.article_size ?? null,
      lead_section_size: snapshot?.lead_section_size ?? null,
      talk_size: snapshot?.talk_size ?? null,
      average_daily_views: snapshot?.average_daily_views ?? null,
      other_article_size: otherSnapshots[title]?.article_size ?? null,
      bubble_article_color: SINGLE_COLOR_PALETTE.article,
      bubble_lead_color: SINGLE_COLOR_PALETTE.lead,
      bubble_talk_color: SINGLE_COLOR_PALETTE.talk,
      bubble_prev_color: SINGLE_COLOR_PALETTE.prevArticle,
    };
  });
}

function yScaleSpec(
  yDomain: SharedScales["yDomain"],
  scaleType: "linear" | "log",
) {
  if (scaleType === "log") {
    const min = yDomain.min > 0 ? yDomain.min : 1;
    return {
      type: "log" as const,
      domainMin: Math.max(1, min) * 0.6,
      domainMax: Math.max(yDomain.max, 1) * 1.8,
    };
  }
  const span = Math.max(yDomain.max - yDomain.min, 1);
  const pad = (MAX_CIRCLE_RADIUS * span) / PANEL_HEIGHT;
  return {
    domainMin: Math.max(0, yDomain.min - pad),
    domainMax: yDomain.max + pad,
  };
}

function sizeEncoding(field: SizeField, scales: SharedScales) {
  return {
    field,
    type: "quantitative" as const,
    scale: {
      type: "sqrt" as const,
      domain: scales.sizeDomains[field],
      range: SIZE_RANGES[field],
    },
  };
}

const DIMMED_OPACITY = 0.12;

function opacityEncoding(base: number) {
  return {
    condition: [
      {
        test: "!hover_article || hover_article === datum.article",
        value: base,
      },
    ],
    value: DIMMED_OPACITY,
  };
}

export function buildTimeTravelSpec({
  rows,
  year,
  otherYear,
  scales,
  xAxisKey,
  xAxisMode,
  xDomain,
  yAxisScaleType,
  showLabels,
}: {
  rows: TimeTravelRow[];
  year: number;
  otherYear: number;
  scales: SharedScales;
  xAxisKey: XAxisKey;
  xAxisMode: "ranked" | "scaled";
  xDomain: [number, number] | [string, string] | null;
  yAxisScaleType: "linear" | "log";
  showLabels: boolean;
}): VisualizationSpec {
  const isScaledMode = xAxisMode === "scaled" && xAxisKey !== "title";

  const xEncoding: any = isScaledMode
    ? {
        field: xAxisKey,
        type: xAxisKey === "publication_date" ? "temporal" : "quantitative",
        axis: {
          title: xAxisTitleForKey(xAxisKey).scaled,
          labels: true,
          ticks: true,
          grid: true,
        },
      }
    : {
        field: "idx",
        type: "quantitative",
        axis: {
          title: xAxisTitleForKey(xAxisKey).ranked,
          labels: false,
          ticks: false,
          grid: false,
        },
      };

  xEncoding.scale = {
    padding: MAX_CIRCLE_RADIUS,
    ...(xDomain ? { domain: xDomain } : {}),
  };

  const yScale = yScaleSpec(scales.yDomain, yAxisScaleType);
  const yEncoding = {
    field: "y_pos",
    type: "quantitative" as const,
    scale: yScale,
    axis: { title: "avg daily visits" },
  };

  const existing = [{ filter: "datum.exists" }];
  const missing = [{ filter: "!datum.exists" }];

  return {
    $schema: "https://vega.github.io/schema/vega-lite/v5.json",
    height: PANEL_HEIGHT,
    width: "container",
    background: "#ffffff",
    data: { name: "main", values: rows },
    config: { legend: { disable: true } },
    resolve: { scale: { size: "independent" } },
    params: [{ name: "hover_article", value: null }],
    transform: [
      {
        calculate: `datum.exists ? datum.average_daily_views : ${yScale.domainMin}`,
        as: "y_pos",
      },
    ],
    encoding: { x: xEncoding },
    layer: [
      {
        mark: { type: "circle", opacity: 0, cursor: "pointer" },
        params: [
          {
            name: "highlight",
            select: {
              type: "point" as const,
              fields: ["article"],
              on: { type: "pointerover", throttle: 50 } as any,
              clear: "pointerout",
            },
          },
        ],
        encoding: {
          y: yEncoding,
          size: { value: 1500 },
        },
      },
      {
        transform: existing,
        mark: { type: "circle", fill: null, strokeWidth: 1.5 },
        encoding: {
          y: yEncoding,
          size: sizeEncoding("talk_size", scales),
          stroke: {
            field: "bubble_talk_color",
            type: "nominal",
            scale: null,
            legend: null,
          },
          opacity: opacityEncoding(1),
        },
      },
      {
        transform: existing,
        mark: {
          type: "circle",
          fill: null,
          strokeDash: [4, 4],
          strokeWidth: 1.5,
        },
        encoding: {
          y: yEncoding,
          size: sizeEncoding("other_article_size", scales),
          stroke: {
            field: "bubble_prev_color",
            type: "nominal",
            scale: null,
            legend: null,
          },
          opacity: opacityEncoding(1),
        },
      },
      {
        transform: existing,
        mark: { type: "circle" },
        encoding: {
          y: yEncoding,
          size: sizeEncoding("lead_section_size", scales),
          fill: {
            field: "bubble_lead_color",
            type: "nominal",
            scale: null,
            legend: null,
          },
          opacity: opacityEncoding(0.8),
        },
      },
      {
        transform: existing,
        mark: {
          type: "circle",
          stroke: "white",
          strokeWidth: 1,
          tooltip: {
            signal: `{
              title: '<div style="display:flex;flex-direction:column"><span style="font-weight:600">' + datum.article + '</span><span style="font-size:12px;color:#666;margin-top:2px">in ${year}</span></div>',
              "Daily visits": isValid(datum.average_daily_views) ? format(datum.average_daily_views, ',') : 'n/a',
              "Size": isValid(datum.article_size) ? format(datum.article_size, ',') : 'n/a',
              "Size in ${otherYear}": isValid(datum.other_article_size) ? format(datum.other_article_size, ',') : 'n/a',
              "Lead size": isValid(datum.lead_section_size) ? format(datum.lead_section_size, ',') : 'n/a',
              "Talk size": isValid(datum.talk_size) ? format(datum.talk_size, ',') : 'n/a',
            }`,
          },
        },
        encoding: {
          y: yEncoding,
          size: sizeEncoding("article_size", scales),
          fill: {
            field: "bubble_article_color",
            type: "nominal",
            scale: null,
            legend: null,
          },
          opacity: opacityEncoding(1),
        },
      },
      {
        transform: missing,
        mark: {
          type: "point",
          shape: "circle",
          filled: false,
          stroke: "#bdbdbd",
          strokeDash: [3, 3],
          strokeWidth: 1.5,
          size: 400,
          tooltip: {
            signal: `{
              title: datum.article,
              "Status": 'Did not exist in ${year}',
              "Created": datum.publication_date ? timeFormat(toDate(datum.publication_date), '%b %d, %Y') : 'unknown',
            }`,
          },
        },
        encoding: {
          y: yEncoding,
          opacity: opacityEncoding(1),
        },
      },
      {
        transform: missing,
        mark: {
          type: "text",
          dy: 22,
          fontSize: 10,
          fill: "#9e9e9e",
          baseline: "top",
        },
        encoding: {
          y: yEncoding,
          text: { value: "non-existent" },
          opacity: opacityEncoding(1),
        },
      },
      ...(showLabels
        ? [
            {
              transform: existing,
              mark: {
                type: "text" as const,
                dy: -26,
                fontSize: 10,
                fill: "#444",
                limit: 90,
              },
              encoding: {
                y: yEncoding,
                text: { field: "article", type: "nominal" as const },
                opacity: opacityEncoding(1),
              },
            },
          ]
        : []),
    ],
  } as VisualizationSpec;
}
