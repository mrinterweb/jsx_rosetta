import React from "react";

export function Button({ children, onClick, variant = "primary" }) {
  return (
    <button
      type="button"
      className={`btn btn-${variant}`}
      onClick={onClick}
    >
      {children}
    </button>
  );
}
