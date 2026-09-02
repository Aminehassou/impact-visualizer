import React, { RefObject, useMemo, useState } from "react";
import { List } from "react-window";
import { FaChevronDown, FaChevronUp } from "react-icons/fa6";
import useOutsideClick from "../hooks/useOutsideClick";
import { MAX_TIME_TRAVEL_ARTICLES } from "../utils/time-travel-vega";

const ITEM_HEIGHT = 34;
const LIST_HEIGHT = 300;

interface PickerRowProps {
  titles: string[];
  selected: Set<string>;
  atCap: boolean;
  onToggle: (title: string) => void;
}

function PickerRow(props: PickerRowProps): React.ReactElement | null {
  const { titles, selected, atCap, onToggle } = props;
  const { index, style } = props as unknown as {
    index: number;
    style: React.CSSProperties;
  };
  const title = titles[index];
  if (!title) return null;

  const isSelected = selected.has(title);
  const isDisabled = atCap && !isSelected;

  return (
    <label
      style={style}
      className={`PickerItem ${isDisabled ? "is-disabled" : ""}`}
      title={
        isDisabled ? `Maximum ${MAX_TIME_TRAVEL_ARTICLES} articles` : title
      }
    >
      <input
        type="checkbox"
        checked={isSelected}
        disabled={isDisabled}
        onChange={() => onToggle(title)}
      />
      <span className="PickerItemLabel">{title}</span>
    </label>
  );
}

export interface TimeTravelArticlePickerProps {
  articleTitles: string[];
  selected: string[];
  onChange: (next: string[]) => void;
}

const TimeTravelArticlePicker: React.FC<TimeTravelArticlePickerProps> = ({
  articleTitles,
  selected,
  onChange,
}) => {
  const [open, setOpen] = useState<boolean>(false);
  const [search, setSearch] = useState<string>("");
  const containerRef = useOutsideClick(() => setOpen(false));

  const selectedSet = useMemo(() => new Set(selected), [selected]);
  const atCap = selected.length >= MAX_TIME_TRAVEL_ARTICLES;

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return articleTitles;
    return articleTitles.filter((title) => title.toLowerCase().includes(term));
  }, [articleTitles, search]);

  const toggle = (title: string) => {
    if (selectedSet.has(title)) {
      onChange(selected.filter((t) => t !== title));
    } else if (!atCap) {
      onChange([...selected, title]);
    }
  };

  return (
    <div
      className="TimeTravelPicker"
      ref={containerRef as RefObject<HTMLDivElement>}
    >
      <button
        type="button"
        className="PickerTrigger"
        aria-expanded={open}
        onClick={() => setOpen((prev) => !prev)}
      >
        <span>
          Articles ({selected.length} of {MAX_TIME_TRAVEL_ARTICLES})
        </span>
        {open ? <FaChevronUp size={12} /> : <FaChevronDown size={12} />}
      </button>

      {open && (
        <div className="PickerPopover">
          <input
            className="PickerSearch"
            type="text"
            value={search}
            placeholder="Search articles"
            onChange={(e) => setSearch(e.target.value)}
          />
          {filtered.length === 0 ? (
            <div className="PickerEmpty">No matching articles</div>
          ) : (
            <List
              className="PickerList"
              rowComponent={PickerRow}
              rowCount={filtered.length}
              rowHeight={ITEM_HEIGHT}
              rowProps={{
                titles: filtered,
                selected: selectedSet,
                atCap,
                onToggle: toggle,
              }}
              overscanCount={10}
              style={{ maxHeight: LIST_HEIGHT }}
            />
          )}
          <div className="PickerFooter">
            <span>
              {selected.length} of {MAX_TIME_TRAVEL_ARTICLES} selected
            </span>
            {selected.length > 0 && (
              <button
                type="button"
                className="ResetLink"
                onClick={() => onChange([])}
              >
                Clear all
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default TimeTravelArticlePicker;
