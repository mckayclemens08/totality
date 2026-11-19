import qrcode from "qrcode-generator";
import { svg } from "./dom";

/** The QR code as SVG elements, so no data: image or markup string is needed. */
export function qrElement(text: string, label: string): SVGElement {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const cells: SVGElement[] = [];
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) {
    if (qr.isDark(r, c)) cells.push(svg("rect", { x: String(c), y: String(r), width: "1", height: "1" }));
  }
  const root = svg("svg", { viewBox: `-2 -2 ${n + 4} ${n + 4}`, width: "216", height: "216", role: "img", "aria-label": label, "shape-rendering": "crispEdges", class: "qr" },
    svg("rect", { x: "-2", y: "-2", width: String(n + 4), height: String(n + 4), fill: "#ffffff" }), ...cells);
  return root;
}
