export function List({ items }) {
  return (
    <ul>
      {items.map((item, index) => (
        <li className={`item item-${index}`}>{item.label}</li>
      ))}
    </ul>
  );
}
