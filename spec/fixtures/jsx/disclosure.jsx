export function Disclosure({ summary, children, open = false }) {
  return (
    <details>
      <summary>{summary}</summary>
      {open && (
        <div className="content">
          {children}
        </div>
      )}
    </details>
  );
}
