import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Paperless Stack",
  description: "Dashboard for the Paperless-ngx document processing pipeline",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-[#0f0f0f] text-neutral-100 antialiased">
        {children}
      </body>
    </html>
  );
}
