import { createFileRoute } from "@tanstack/react-router";
import { PersonalScreen } from "@/features/personal/PersonalScreen";

export const Route = createFileRoute("/library")({
  validateSearch: (search: Record<string, unknown>): { item?: string } => ({
    item: typeof search.item === "string" ? search.item : undefined,
  }),
  component: LibraryRoute,
});
function LibraryRoute() {
  const { item } = Route.useSearch();
  return <PersonalScreen section="library" itemId={item} />;
}
