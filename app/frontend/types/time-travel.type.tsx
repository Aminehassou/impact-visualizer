type TimeTravelYAxisKey =
  "average_daily_views" | "article_size" | "edits_in_period";

type TimeTravelSnapshot = {
  article_size: number | null;
  lead_section_size: number | null;
  talk_size: number | null;
  average_daily_views: number | null;
  edits_in_period?: number | null;
  edits_in_period_capped?: boolean;
};

type TimeTravelResponse = Record<
  string,
  Record<string, TimeTravelSnapshot | null>
>;

type TimeTravelRow = {
  article: string;
  idx: number;
  exists: boolean;
  publication_date: string | null;
  article_size: number | null;
  lead_section_size: number | null;
  talk_size: number | null;
  average_daily_views: number | null;
  edits_in_period: number | null;
  edits_in_period_capped: boolean;
  other_article_size: number | null;
  other_lead_section_size: number | null;
  other_talk_size: number | null;
  other_average_daily_views: number | null;
  other_edits_in_period: number | null;
  bubble_article_color: string;
  bubble_lead_color: string;
  bubble_talk_color: string;
};

export type {
  TimeTravelSnapshot,
  TimeTravelResponse,
  TimeTravelRow,
  TimeTravelYAxisKey,
};
