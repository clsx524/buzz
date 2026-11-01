import { createFileRoute } from "@tanstack/react-router";
import { PersonalScreen } from "@/features/personal/PersonalScreen";

export const Route = createFileRoute("/today")({
  validateSearch: (search: Record<string, unknown>): { item?: string } => ({
    item: typeof search.item === "string" ? search.item : undefined,
  }),
  component: TodayRoute,
});
function TodayRoute() {
  const { item } = Route.useSearch();
  return <PersonalScreen section="today" itemId={item} />;
}
