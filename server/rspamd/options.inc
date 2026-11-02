# Nothing here can reach the internet, so it doesn't try.
disable_monitoring = true;
dns {
  timeout = 1s;
  retransmits = 1;
}
