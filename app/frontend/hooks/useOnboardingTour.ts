import { useEffect, useRef, useState } from "react";

const ONBOARDING_STORAGE_KEY = "iv:onboarding:wiki-bubble-chart:v1";

function hasSeenTour(): boolean {
  try {
    return localStorage.getItem(ONBOARDING_STORAGE_KEY) !== null;
  } catch {
    return true;
  }
}

function markTourSeen() {
  try {
    localStorage.setItem(ONBOARDING_STORAGE_KEY, new Date().toISOString());
  } catch {
    /* storage unavailable */
  }
}

interface UseOnboardingTourOptions {
  hasData: boolean;
}

function useOnboardingTour({ hasData }: UseOnboardingTourOptions) {
  const [run, setRun] = useState(false);
  const [stepIndex, setStepIndex] = useState(0);
  const [isFirstVisit] = useState(() => !hasSeenTour());
  const autoStarted = useRef(false);

  useEffect(() => {
    if (isFirstVisit && hasData && !autoStarted.current) {
      autoStarted.current = true;
      setRun(true);
    }
  }, [isFirstVisit, hasData]);

  const startTour = () => {
    setStepIndex(0);
    setRun(true);
  };

  const endTour = () => {
    setRun(false);
    markTourSeen();
  };

  return { run, stepIndex, setStepIndex, startTour, endTour };
}

export { useOnboardingTour, ONBOARDING_STORAGE_KEY, hasSeenTour, markTourSeen };
