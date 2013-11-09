plack: plackup -s Starlet --max-workers 4 --max-reqs-per-child 50000 --socket-path /tmp/app.sock -E production app.psgi
worker: perl ./worker.pl

