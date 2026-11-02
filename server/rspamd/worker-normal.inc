# The only worker. The mail service is its only client, on a network with no way out.
bind_socket = "*:11333";
count = 1;
