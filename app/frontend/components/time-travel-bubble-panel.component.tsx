import React, { useEffect, useRef } from "react";
import vegaEmbed, { EmbedOptions, Result, VisualizationSpec } from "vega-embed";
import { patchChartScales } from "../utils/bubble-chart-vega";

export interface TimeTravelBubblePanelProps {
  year: number;
  spec: VisualizationSpec;
  onHover: (article: string | null) => void;
  onReady: (view: Result | null) => void;
}

const TimeTravelBubblePanel: React.FC<TimeTravelBubblePanelProps> = ({
  year,
  spec,
  onHover,
  onReady,
}) => {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const onHoverRef = useRef(onHover);
  const onReadyRef = useRef(onReady);
  onHoverRef.current = onHover;
  onReadyRef.current = onReady;

  useEffect(() => {
    if (!containerRef.current) return;

    const options: EmbedOptions = {
      actions: false,
      renderer: "canvas",
      mode: "vega-lite",
      patch: patchChartScales as EmbedOptions["patch"],
      tooltip: {
        sanitize: (value: string) => value,
      } as EmbedOptions["tooltip"],
    };

    let result: Result | null = null;
    let cancelled = false;

    vegaEmbed(containerRef.current, spec, options)
      .then((embedded) => {
        if (cancelled) {
          embedded.view.finalize();
          return;
        }
        result = embedded;
        embedded.view.addSignalListener("highlight", (_name, value: any) => {
          onHoverRef.current(value?.article?.[0] ?? null);
        });
        onReadyRef.current(embedded);
      })
      .catch(console.error);

    return () => {
      cancelled = true;
      onReadyRef.current(null);
      result?.view.finalize();
    };
  }, [spec]);

  return (
    <div className="Panel">
      <div className="PanelHeader">{year}</div>
      <div className="PanelBody" ref={containerRef} />
    </div>
  );
};

export default TimeTravelBubblePanel;
