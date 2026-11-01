import * as React from "react";
import type { AssistantConcern, AssistantDashboard, AssistantDecision, AssistantQuestion } from "./assistantClient";
import type { AssistantRun } from "./WatchEditor";
import { AdvancedDetail, AssistantEvidence, AssistantField, assistantButtonClass as button, assistantInputClass as input, assistantError, objectValue } from "./AssistantEvidence";

function serverChannel(value: unknown): string | undefined {
  const channel = objectValue(value).channel_id;
  return typeof channel === "string" && channel.trim() ? channel : undefined;
}
function ConversationLink({ value, openConversation }: { value: unknown; openConversation?: (channelId: string) => void }) {
  const channel = serverChannel(value);
  return channel && openConversation ? <button className={button} onClick={() => openConversation(channel)}>Open conversation</button> : null;
}

function Question({ question, run, busy, refresh }: { question: AssistantQuestion; run: AssistantRun; busy: boolean; refresh: () => void }) {
  const [answer, setAnswer] = React.useState("");
  const [error, setError] = React.useState("");
  return <article className="space-y-3 rounded-lg border p-4" aria-label={`Question: ${question.prompt}`}>
    <p className="font-medium">{question.prompt}</p>
    <p className="break-all text-xs text-muted-foreground">Question {question.id} · Finding {question.concern_id}</p>
    {question.answer !== null ? <p className="whitespace-pre-wrap text-sm">Your answer: {question.answer}</p> : <form className="space-y-2" onSubmit={(event) => {
      event.preventDefault(); setError("");
      void run({ resource: "concerns", action: "answer", question_id: question.id, answer }).then(() => { setAnswer(""); refresh(); }).catch((failure) => setError(assistantError(failure)));
    }}><AssistantField label="Your answer"><textarea className={input} required maxLength={8000} disabled={busy} value={answer} onChange={(event) => setAnswer(event.target.value)} /></AssistantField><button className={button} disabled={busy || !answer.trim()}>Send answer</button></form>}
    {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
  </article>;
}

function Decision({ decision, busy, run }: { decision: AssistantDecision; busy: boolean; run: AssistantRun }) {
  const [signal, setSignal] = React.useState("useful");
  const [comment, setComment] = React.useState("");
  const [preference, setPreference] = React.useState("");
  const [message, setMessage] = React.useState("");
  const [error, setError] = React.useState("");
  return <article aria-label={`Decision: ${decision.title}`} className="space-y-3 rounded-lg border p-4">
    <h4 className="font-medium">{decision.title}</h4>
    <p className="text-xs text-muted-foreground">{decision.kind} · {new Date(decision.created * 1000).toLocaleString()} · Decision {decision.id}</p>
    {decision.summary ? <p className="whitespace-pre-wrap text-sm">{decision.summary}</p> : null}
    {decision.rationale ? <div><h5 className="text-sm font-medium">Why your assistant decided this</h5><p className="whitespace-pre-wrap text-sm text-muted-foreground">{decision.rationale}</p></div> : null}
    {decision.gate ? <details><summary className="min-h-11 cursor-pointer py-3 text-sm">Decision model details</summary><AssistantEvidence value={decision.gate} /></details> : null}
    <details><summary className="min-h-11 cursor-pointer py-3 text-sm">Give feedback or set a preference</summary><form className="space-y-3" onSubmit={(event) => {
      event.preventDefault(); setError(""); setMessage("");
      void run({ resource: "feedback", action: "submit", decision_id: decision.id, signal, ...(comment.trim() ? { comment } : {}), ...(preference.trim() ? { preference } : {}) }).then(() => { setMessage("Feedback saved."); setComment(""); setPreference(""); }).catch((failure) => setError(assistantError(failure)));
    }}><fieldset disabled={busy} className="space-y-3">
      <AssistantField label="Feedback"><select className={input} value={signal} onChange={(event) => setSignal(event.target.value)}><option value="useful">Useful</option><option value="irrelevant">Not relevant</option><option value="digest">Prefer digest</option><option value="already_handled">Already handled</option><option value="incorrect">Incorrect</option><option value="missed">Missed something</option></select></AssistantField>
      <AssistantField label="Feedback comment"><textarea className={input} value={comment} onChange={(event) => setComment(event.target.value)} /></AssistantField>
      <AssistantField label="Preference to remember" hint="Optional explicit instruction to apply immediately and remember for this profile."><textarea className={input} value={preference} onChange={(event) => setPreference(event.target.value)} /></AssistantField>
      <button className={button}>Submit feedback</button>
    </fieldset></form></details>
    {message ? <p role="status" className="text-sm">{message}</p> : null}{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
    <AdvancedDetail value={decision} />
  </article>;
}

function Finding({ concern, decisions, questions, run, busy, refresh, openConversation }: {
  concern: AssistantConcern; decisions: AssistantDecision[]; questions: AssistantQuestion[]; run: AssistantRun; busy: boolean; refresh: () => void; openConversation?: (id: string) => void;
}) {
  const [evidence, setEvidence] = React.useState<unknown>();
  const [error, setError] = React.useState("");
  const [snooze, setSnooze] = React.useState("3600");
  const inspectEpoch = React.useRef(0);
  React.useEffect(() => () => { inspectEpoch.current++; }, []);
  const act = (action: string) => {
    setError("");
    const seconds = Number(snooze);
    if (action === "snooze" && (!Number.isInteger(seconds) || seconds <= 0)) { setError("Snooze duration must be a positive whole number of seconds."); return; }
    const epoch = ++inspectEpoch.current;
    void run({ resource: "concerns", action, concern_id: concern.id, ...(action === "snooze" ? { seconds } : {}) }).then((response) => {
      if (epoch !== inspectEpoch.current) return;
      if (action === "inspect") setEvidence(response);
      else { setEvidence(undefined); refresh(); }
    }).catch((failure) => { if (epoch === inspectEpoch.current) setError(assistantError(failure)); });
  };
  const detail = objectValue(evidence);
  return <article className="space-y-3 rounded-xl border p-4" aria-label={`Finding: ${concern.title}`}>
    <h4 className="font-semibold">{concern.title}</h4>
    <p className="text-xs capitalize text-muted-foreground">{concern.status}</p>
    {concern.summary ? <p className="whitespace-pre-wrap text-sm">{concern.summary}</p> : null}
    <dl className="grid gap-2 text-xs sm:grid-cols-2"><div><dt className="text-muted-foreground">Finding ID</dt><dd className="break-all">{concern.id}</dd></div>{concern.watch_id ? <div><dt className="text-muted-foreground">Monitor</dt><dd className="break-all">{concern.watch_id}</dd></div> : null}{concern.record_id ? <div><dt className="text-muted-foreground">Source record</dt><dd className="break-all">{concern.record_id}</dd></div> : null}</dl>
    <div className="flex flex-wrap gap-2"><button className={button} disabled={busy} onClick={() => act("inspect")}>Inspect evidence</button><button className={button} disabled={busy} onClick={() => act("handled")}>Mark handled</button><button className={button} disabled={busy} onClick={() => act("resume")}>Resume finding</button><ConversationLink value={concern} openConversation={openConversation} /></div>
    <div className="flex flex-wrap items-end gap-2"><AssistantField label="Snooze duration"><select className={input} disabled={busy} value={snooze} onChange={(event) => setSnooze(event.target.value)}><option value="3600">1 hour</option><option value="86400">1 day</option><option value="604800">1 week</option></select></AssistantField><button className={button} disabled={busy} onClick={() => act("snooze")}>Snooze finding</button></div>
    {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
    {evidence !== undefined ? (
      <section aria-label="Finding evidence" className="space-y-3 border-t pt-3">
        <h5 className="font-medium">Evidence & history</h5>
        <p className="text-xs text-muted-foreground">Server-supplied observations, decisions and delivery records. Missing sources are not inferred.</p>
        <AssistantEvidence value={Array.isArray(detail.events) ? detail.events.map((event) => objectValue(event).payload ?? event) : detail.events} />
        <ConversationLink value={detail} openConversation={openConversation} />
        {["conversation_links", "delivery_links"].map((key) => {
          const links = detail[key];
          return Array.isArray(links) ? links.map((link, index) => (
            <ConversationLink key={`${key}:${index}`} value={link} openConversation={openConversation} />
          )) : null;
        })}
        <AdvancedDetail value={evidence} />
      </section>
    ) : null}
    {questions.length ? <section className="space-y-3"><h5 className="font-medium">Questions</h5>{questions.map((question) => <Question key={question.id} question={question} busy={busy} run={run} refresh={refresh} />)}</section> : null}
    {decisions.length ? <section className="space-y-3"><h5 className="font-medium">Decisions</h5>{decisions.map((decision) => <Decision key={decision.id} decision={decision} busy={busy} run={run} />)}</section> : null}
  </article>;
}

export function AssistantActivity({ dashboard, run, busy, refresh, openConversation }: {
  dashboard: AssistantDashboard; run: AssistantRun; busy: boolean; refresh: () => void; openConversation?: (id: string) => void;
}) {
  const concernIds = new Set(dashboard.concerns.map((concern) => concern.id));
  const remainingQuestions = dashboard.questions.filter((question) => !concernIds.has(question.concern_id));
  const remainingDecisions = dashboard.decisions.filter((decision) => !concernIds.has(decision.concern_id));
  return <section aria-label="Findings and questions" className="space-y-4"><h3 className="text-lg font-semibold">Findings & questions</h3>
    {!dashboard.concerns.length && !dashboard.questions.length && !dashboard.decisions.length ? <p className="text-sm text-muted-foreground">No findings, decisions or questions returned by your assistant.</p> : null}
    {dashboard.concerns.map((concern) => <Finding key={concern.id} concern={concern} decisions={dashboard.decisions.filter((decision) => decision.concern_id === concern.id)} questions={dashboard.questions.filter((question) => question.concern_id === concern.id)} run={run} busy={busy} refresh={refresh} openConversation={openConversation} />)}
    {remainingQuestions.map((question) => <Question key={question.id} question={question} run={run} busy={busy} refresh={refresh} />)}
    {remainingDecisions.map((decision) => <Decision key={decision.id} decision={decision} run={run} busy={busy} />)}
  </section>;
}
