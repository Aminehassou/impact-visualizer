import React, { useEffect, useRef, useMemo } from "react";
import vegaEmbed, { VisualizationSpec, EmbedOptions, Result } from "vega-embed";

type ArticleAnalytics = {
  average_daily_views: number;
  article_size: number;
  prev_article_size: number | null;
  talk_size: number;
  prev_talk_size: number | null;
  lead_section_size: number;
  prev_average_daily_views: number | null;
};

interface WikiBubbleChartProps {
  data?: Record<string, ArticleAnalytics>;
  actions?: boolean;
}

const STEP = 25;
const MIN_WIDTH = 650;
const HEIGHT = 650;

export const WikiBubbleChart: React.FC<WikiBubbleChartProps> = ({
  data = {},
  actions = false,
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<Result | null>(null);
  const rows = useMemo(() => {
    if (data && typeof data === "object") {
      return Object.entries(data).map(([article, analytics]) => ({
        article,
        ...analytics,
      }));
    }
    return [];
  }, [data]);

  useEffect(() => {
    if (!containerRef.current) return;

    const spec: VisualizationSpec = {
      $schema: "https://vega.github.io/schema/vega-lite/v5.json",
      width: Math.max(MIN_WIDTH, rows.length * STEP + 120),
      height: HEIGHT,
      padding: { left: 25, top: 25, right: 60, bottom: 60 },
      background: "#ffffff",
      data: { values: rows },
      config: {
        legend: { disable: true },
      },
      layer: [
        {
          mark: {
            type: "circle",
            opacity: 0,
          },
          params: [
            {
              name: "highlight",
              select: {
                type: "point",
                fields: ["article"],
                on: "mouseover",
                clear: "mouseout",
              },
            },
          ],
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "average_daily_views", type: "quantitative" },
          },
        },
        {
          mark: {
            type: "rule",
            strokeDash: [2, 4],
            strokeWidth: 1.2,
            opacity: 0.6,
          },
          encoding: {
            x: { field: "article", type: "nominal", axis: null },
            y: { field: "prev_average_daily_views", type: "quantitative" },
            y2: { field: "average_daily_views", type: "quantitative" },
          },
        },

        // Discussion size circle (talk_size)
        {
          mark: {
            type: "circle",
            fill: null,
            stroke: "#2196f3",
            strokeWidth: 1.5,
          },
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "average_daily_views", type: "quantitative" },
            size: {
              field: "talk_size",
              type: "quantitative",
              scale: { type: "sqrt", range: [50, 1500] },
            },
            opacity: {
              condition: { param: "highlight", value: 1 },
              value: 0.2,
            },
          },
        },
        // Previous article size circle (prev_article_size)
        {
          mark: {
            type: "circle",
            fill: null,
            strokeDash: [4, 4],
            stroke: "#64b5f6",
            strokeWidth: 1.5,
          },
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "average_daily_views", type: "quantitative" },
            size: {
              field: "prev_article_size",
              type: "quantitative",
              scale: { type: "sqrt", range: [20, 600] },
            },
            opacity: {
              condition: { param: "highlight", value: 1 },
              value: 0.2,
            },
          },
        },
        // Lead section size circle (lead_section_size)
        {
          mark: { type: "circle", fill: "#90caf9", opacity: 0.8 },
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "average_daily_views", type: "quantitative" },
            size: {
              field: "lead_section_size",
              type: "quantitative",
              scale: { type: "sqrt", range: [30, 800] },
            },
            opacity: {
              condition: { param: "highlight", value: 0.8 },
              value: 0.2,
            },
          },
        },
        // Article size circle (article_size)
        {
          mark: {
            type: "circle",
            fill: "#0d47a1",
            opacity: 0.5,
            stroke: "white",
            strokeWidth: 1,
          },
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "average_daily_views", type: "quantitative" },
            size: {
              field: "article_size",
              type: "quantitative",
              scale: { type: "sqrt", range: [20, 600] },
            },
            opacity: {
              condition: { param: "highlight", value: 0.5 },
              value: 0.2,
            },
            tooltip: [
              { field: "article", title: "Article" },
              { field: "average_daily_views", title: "Daily visits" },
              {
                field: "prev_average_daily_views",
                title: "Daily visits (prev year)",
              },
              { field: "article_size", title: "Size" },
              { field: "prev_article_size", title: "Size (prev year)" },
              { field: "lead_section_size", title: "Lead size" },
              { field: "talk_size", title: "Talk size" },
              { field: "prev_talk_size", title: "Talk size (prev year)" },
            ],
          },
        },
        {
          transform: [
            { filter: "datum.improved" },
            {
              calculate: "datum.avg_pv + sqrt(datum.size) * 0.2 + 5",
              as: "triangle_y",
            },
          ],
          mark: {
            type: "point",
            shape: "triangle-up",
            size: 5,
            fill: "#000",
            stroke: "#000",
          },
          encoding: {
            x: { field: "article", type: "nominal" },
            y: { field: "triangle_y", type: "quantitative" },
          },
        },
      ],

      encoding: {
        x: {
          field: "article",
          type: "nominal",
          axis: { labelAngle: -40, title: null, tickSize: 0 },
        },
        y: {
          field: "average_daily_views",
          type: "quantitative",
          axis: { title: "avg daily visits" },
        },
      },

      resolve: { scale: { size: "independent" } },
    };

    const options: EmbedOptions = {
      actions,
      renderer: "canvas",
      mode: "vega-lite",
    };

    vegaEmbed(containerRef.current, spec, options)
      .then((result) => {
        viewRef.current = result;
      })
      .catch(console.error);

    return () => {
      viewRef.current?.view.finalize();
      viewRef.current = null;
    };
  }, [rows, actions]);

  return (
    <div>
      <div
        style={{
          overflowX: "auto",
          overflowY: "hidden",
          maxWidth: "100%",
        }}
        ref={containerRef}
      />

      {/* Legend */}
      <div
        style={{
          marginTop: "8px",
          display: "flex",
          gap: "16px",
          flexWrap: "wrap",
          alignItems: "center",
          fontSize: "0.9rem",
        }}
      >
        {/* Article size */}
        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
          <span
            style={{
              display: "inline-block",
              width: "12px",
              height: "12px",
              borderRadius: "50%",
              backgroundColor: "rgba(13, 71, 161, 0.5)",
            }}
          />
          <span>Article size (bytes)</span>
        </div>

        {/* Lead section size */}
        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
          <span
            style={{
              display: "inline-block",
              width: "12px",
              height: "12px",
              borderRadius: "50%",
              backgroundColor: "#90caf9",
            }}
          />
          <span>Lead section size (bytes)</span>
        </div>

        {/* Discussion size */}
        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
          <span
            style={{
              display: "inline-block",
              width: "12px",
              height: "12px",
              borderRadius: "50%",
              border: "2px solid #2196f3",
              backgroundColor: "transparent",
            }}
          />
          <span>Discussion size (bytes)</span>
        </div>

        {/* Previous article size */}
        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
          <span
            style={{
              display: "inline-block",
              width: "12px",
              height: "12px",
              borderRadius: "50%",
              border: "2px dashed #64b5f6",
              backgroundColor: "transparent",
            }}
          />
          <span>Prev. article size (bytes)</span>
        </div>

        {/* Daily views change (dotted line) */}
        <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
          <span
            style={{
              display: "inline-block",
              width: "16px",
              height: "0",
              borderTop: "2px dashed #757575",
            }}
          />
          <span>Change in daily views</span>
        </div>
      </div>
    </div>
  );
};

export default WikiBubbleChart;
