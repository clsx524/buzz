import { createFileRoute } from "@tanstack/react-router";
import { PersonalScreen } from "@/features/personal/PersonalScreen";

export const Route = createFileRoute("/conversations")({
  component: () => <PersonalScreen section="conversations" />,
});
