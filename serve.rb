#!/usr/bin/env ruby
require 'webrick'

# Create a simple HTTP server
server = WEBrick::HTTPServer.new(
  Port: 8000,
  DocumentRoot: Dir.pwd
)

# Only mount the index page, let DocumentRoot handle everything else
server.mount_proc '/' do |req, res|
  # Only handle the root path, let other paths fall through
  if req.path == '/'
    res.body = <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Remark Slides - Metropolis Theme</title>
          <meta charset="utf-8">
          <link rel="stylesheet" href="metropolis.css">
          <link rel="stylesheet" href="metropolis-fonts.css">
          <style>
            /* Additional styling for code blocks */
            .remark-code {
              background: #f5f5f5;
              padding: 0.5em;
              border-radius: 3px;
            }
            
            .remark-inline-code {
              background: #e7e8e2;
              padding: 0.1em 0.3em;
              border-radius: 3px;
            }
          </style>
        </head>
        <body>
          <script src="remark-latest.min.js"></script>
          <script>
            var slideshow = remark.create({
              sourceUrl: 'slides.md',
              highlightStyle: 'github',
              ratio: '16:9'
            });
          </script>
        </body>
      </html>
    HTML
    res.content_type = 'text/html'
  else
    # Let WEBrick's default handler serve static files
    WEBrick::HTTPServlet::FileHandler.new(server, Dir.pwd).service(req, res)
  end
end

# Graceful shutdown on Ctrl-C
trap('INT') { server.shutdown }

puts "Server running at http://localhost:8000 (Metropolis theme)"
puts "Press Ctrl-C to stop"

server.start
