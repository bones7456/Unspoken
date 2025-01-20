class ChatViewModel {
    constructor() {
        this.messages = [];
        this.typingContent = "";
        this.isChatOpen = false;
        this.roomId = "";
        this.serverAddress = "ws://18.138.249.97:8765";
        this.role = "";
        this.userId = this.generateUUID();
        this.socket = null;
        this.privateKey = null;
        this.publicKey = null;
        this.peerPublicKey = null;
        this.peerUserId = null;
        
        this.generateKeyPair();
    }

    generateUUID() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
            return v.toString(16);
        });
    }

    async generateKeyPair() {
        const keyPair = await window.crypto.subtle.generateKey(
            {
                name: "RSA-OAEP",
                modulusLength: 2048,
                publicExponent: new Uint8Array([1, 0, 1]),
                hash: "SHA-256",
            },
            true,
            ["encrypt", "decrypt"]
        );
        this.privateKey = keyPair.privateKey;
        this.publicKey = keyPair.publicKey;
        console.log("Key pair generated.");
    }

    setupWebSocket() {
        this.socket = new WebSocket(this.serverAddress);
        this.socket.onopen = () => {
            console.log("WebSocket connected");
            if (this.pendingAction) {
                this.pendingAction();
                this.pendingAction = null;
            }
        };
        this.socket.onmessage = (event) => this.handleMessage(event.data);
        this.socket.onerror = (error) => console.error("WebSocket error:", error);
        this.socket.onclose = () => console.log("WebSocket disconnected");
    }

    async sendLogin() {
        const publicKeyData = await window.crypto.subtle.exportKey("spki", this.publicKey);
        const publicKeyBase64 = btoa(String.fromCharCode.apply(null, new Uint8Array(publicKeyData)));
        this.sendJSON({action: "login", user_id: this.userId, public_key: publicKeyBase64});
    }

    createRoom() {
        this.pendingAction = () => {
            this.sendLogin();
            this.sendJSON({action: "create_room"});
        };
        this.setupWebSocket();
    }

    joinRoom() {
        this.pendingAction = () => {
            this.sendLogin();
            this.sendJSON({action: "join_room", room_id: this.roomId});
        };
        this.setupWebSocket();
    }

    leaveRoom() {
        this.sendJSON({action: "leave_room", room_id: this.roomId, role: this.role});
        this.isChatOpen = false;
        this.roomId = "";
        this.role = "";
        this.messages = [];
    }

    async encryptMessage(message) {
        if (!this.peerPublicKey) {
            console.error("Peer public key not available");
            return null;
        }

        const encoder = new TextEncoder();
        const messageData = encoder.encode(message);

        const aesKey = await window.crypto.subtle.generateKey(
            { name: "AES-GCM", length: 256 },
            true,
            ["encrypt", "decrypt"]
        );

        const iv = window.crypto.getRandomValues(new Uint8Array(12));
        const encryptedMessage = await window.crypto.subtle.encrypt(
            { name: "AES-GCM", iv: iv },
            aesKey,
            messageData
        );

        const exportedAesKey = await window.crypto.subtle.exportKey("raw", aesKey);
        const encryptedAesKey = await window.crypto.subtle.encrypt(
            { name: "RSA-OAEP" },
            this.peerPublicKey,
            exportedAesKey
        );

        return {
            encryptedAesKey: btoa(String.fromCharCode.apply(null, new Uint8Array(encryptedAesKey))),
            encryptedMessage: btoa(String.fromCharCode.apply(null, new Uint8Array(encryptedMessage))),
            iv: btoa(String.fromCharCode.apply(null, iv))
        };
    }

    async decryptMessage(encryptedAesKey, encryptedMessage, iv) {
        const decryptedAesKey = await window.crypto.subtle.decrypt(
            { name: "RSA-OAEP" },
            this.privateKey,
            Uint8Array.from(atob(encryptedAesKey), c => c.charCodeAt(0))
        );

        const aesKey = await window.crypto.subtle.importKey(
            "raw",
            decryptedAesKey,
            { name: "AES-GCM", length: 256 },
            false,
            ["decrypt"]
        );

        const decryptedData = await window.crypto.subtle.decrypt(
            { name: "AES-GCM", iv: Uint8Array.from(atob(iv), c => c.charCodeAt(0)) },
            aesKey,
            Uint8Array.from(atob(encryptedMessage), c => c.charCodeAt(0))
        );

        const decoder = new TextDecoder();
        return decoder.decode(decryptedData);
    }

    async sendTyping(content) {
        const encrypted = await this.encryptMessage(content);
        if (encrypted) {
            this.sendJSON({
                action: "typing",
                room_id: this.roomId,
                role: this.role,
                encrypted_aes_key: encrypted.encryptedAesKey,
                encrypted_content: encrypted.encryptedMessage,
                iv: encrypted.iv
            });
        }
    }

    async sendMessage(content) {
        const encrypted = await this.encryptMessage(content);
        if (encrypted) {
            this.sendJSON({
                action: "send_message",
                room_id: this.roomId,
                role: this.role,
                encrypted_aes_key: encrypted.encryptedAesKey,
                encrypted_content: encrypted.encryptedMessage,
                iv: encrypted.iv
            });
            this.messages.push({content: content, isFromMe: true, isTyping: false});
        }
    }

    sendJSON(data) {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            this.socket.send(JSON.stringify(data));
        } else {
            console.error("WebSocket is not open");
        }
    }

    async handleMessage(message) {
        const data = JSON.parse(message);
        switch (data.action) {
            case "room_created":
            case "room_joined":
                this.roomId = data.room_id;
                this.role = data.role;
                this.isChatOpen = true;
                if (data.peer_user_id && data.peer_public_key) {
                    await this.setPeerPublicKey(data.peer_user_id, data.peer_public_key);
                }
                break;
            case "user_joined":
                if (data.peer_role && data.peer_user_id && data.peer_public_key) {
                    await this.setPeerPublicKey(data.peer_user_id, data.peer_public_key);
                    this.messages.push({content: `${data.peer_role.charAt(0).toUpperCase() + data.peer_role.slice(1)} joined, Encrypted channel established, enjoy!`, isFromMe: false, isTyping: false, isSystem: true});
                }
                break;
            case "user_left":
                if (data.role) {
                    this.messages.push({content: `${data.role.charAt(0).toUpperCase() + data.role.slice(1)} has left the room.`, isFromMe: false, isTyping: false, isSystem: true});
                }
                break;
            case "room_closed":
                this.messages.push({content: "Host has left the room. The room is closed.", isFromMe: false, isTyping: false, isSystem: true});
                setTimeout(() => this.leaveRoom(), 2000);
                break;
            case "typing":
                if (data.encrypted_aes_key && data.encrypted_content && data.iv) {
                    const decryptedContent = await this.decryptMessage(data.encrypted_aes_key, data.encrypted_content, data.iv);
                    this.typingContent = decryptedContent;
                }
                break;
            case "new_message":
                if (data.encrypted_aes_key && data.encrypted_content && data.iv) {
                    const decryptedContent = await this.decryptMessage(data.encrypted_aes_key, data.encrypted_content, data.iv);
                    this.messages.push({content: decryptedContent, isFromMe: false, isTyping: false});
                }
                break;
            case "error":
                console.error("Error:", data.message);
                break;
        }
        this.render();
    }

    async setPeerPublicKey(peerUserId, publicKeyBase64) {
        const publicKeyData = Uint8Array.from(atob(publicKeyBase64), c => c.charCodeAt(0));
        this.peerPublicKey = await window.crypto.subtle.importKey(
            "spki",
            publicKeyData,
            { name: "RSA-OAEP", hash: "SHA-256" },
            true,
            ["encrypt"]
        );
        this.peerUserId = peerUserId;
        console.log("Received and set peer public key");
    }

    render() {
        // 这个方法将在后面实现
    }
}

// 创建视图和事件处理逻辑
function createApp() {
    const viewModel = new ChatViewModel();
    const app = document.getElementById('app');

    function render() {
        if (viewModel.isChatOpen) {
            renderChatView();
        } else {
            renderRoomSelectionView();
        }
    }

    function renderRoomSelectionView() {
        app.innerHTML = `
            <div class="room-selection">
                <h1>Unspoken</h1>
                <div class="server-settings">
                    <input type="text" id="serverAddress" placeholder="Server Address" value="${viewModel.serverAddress.split('://')[1].split(':')[0]}">
                    <input type="text" id="serverPort" placeholder="Port" value="${viewModel.serverAddress.split(':')[2]}">
                </div>
                <div class="room-actions">
                    <input type="text" id="roomId" placeholder="Room ID">
                    <button id="joinRoom">Join Room</button>
                    <button id="createRoom">Create Room</button>
                </div>
                <div class="terms">
                    <input type="checkbox" id="agreeTerms">
                    <label for="agreeTerms">I agree to the <a href="http://unspoken.luy.li/EULA.html" target="_blank">EULA</a> and <a href="http://unspoken.luy.li/Privacy.html" target="_blank">Privacy Policy</a></label>
                </div>
            </div>
        `;

        document.getElementById('joinRoom').addEventListener('click', () => {
            const roomId = document.getElementById('roomId').value;
            if (roomId && document.getElementById('agreeTerms').checked) {
                viewModel.roomId = roomId;
                viewModel.role = 'guest';
                viewModel.joinRoom();
            }
        });

        document.getElementById('createRoom').addEventListener('click', () => {
            if (document.getElementById('agreeTerms').checked) {
                viewModel.role = 'host';
                viewModel.createRoom();
            }
        });

        document.getElementById('serverAddress').addEventListener('change', updateServerAddress);
        document.getElementById('serverPort').addEventListener('change', updateServerAddress);

        function updateServerAddress() {
            const address = document.getElementById('serverAddress').value;
            const port = document.getElementById('serverPort').value;
            viewModel.serverAddress = `ws://${address}:${port}`;
        }
    }

    function renderChatView() {
        app.innerHTML = `
            <div class="chat-view">
                <div class="chat-header">
                    <span>Room: ${viewModel.roomId}</span>
                    <button id="leaveRoom">Leave</button>
                </div>
                <div class="chat-messages" id="chatMessages"></div>
                <div class="chat-input">
                    <input type="text" id="messageInput" placeholder="Type a message">
                    <button id="sendMessage">Send</button>
                </div>
            </div>
        `;

        const chatMessages = document.getElementById('chatMessages');
        chatMessages.innerHTML = viewModel.messages.map(message => `
            <div class="message ${message.isFromMe ? 'from-me' : 'from-them'} ${message.isSystem ? 'system' : ''}">
                ${message.content}
            </div>
        `).join('');

        if (viewModel.typingContent) {
            chatMessages.innerHTML += `
                <div class="message from-them typing">
                    ${viewModel.typingContent}
                </div>
            `;
        }

        chatMessages.scrollTop = chatMessages.scrollHeight;

        document.getElementById('leaveRoom').addEventListener('click', () => viewModel.leaveRoom());

        const messageInput = document.getElementById('messageInput');
        messageInput.addEventListener('input', () => viewModel.sendTyping(messageInput.value));

        document.getElementById('sendMessage').addEventListener('click', sendMessage);
        messageInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        function sendMessage() {
            const content = messageInput.value.trim();
            if (content) {
                viewModel.sendMessage(content);
                messageInput.value = '';
            }
        }
    }

    viewModel.render = render;
    // 立即调用render函数以显示初始内容
    render();
}

// 确保在DOM加载完成后执行createApp
document.addEventListener('DOMContentLoaded', createApp);