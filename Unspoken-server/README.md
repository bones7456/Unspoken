
# Unspoken Server

  

A WebSocket server for the Unspoken chat APP that handles encrypted real-time messaging between users.

  

## Features

  

- Real-time messaging with WebSocket

- End-to-end encryption support

- Room-based chat system

- Typing indicators

- Auto room cleanup

  

## Requirements

  

- Python 3.7+

-  `websockets` library

-  `cryptography` library

  

## Installation

  

1. Clone the repository:

```bash

git  clone  https://github.com/yourusername/Unspoken-server.git

cd  Unspoken-server

```

  

2. Install required packages:

```bash

pip  install  websockets  cryptography

```

  

## Usage

  

1. Start the server:

```bash

python  unspoken.py

```

  

The server will start running on `0.0.0.0:8765` by default.

  

## Configuration

  

You can modify the following variables in `unspoken.py`:

-  `HOST`: Server host address (default: "0.0.0.0")

-  `PORT`: Server port number (default: 8765)

  

## Contributing

  

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.