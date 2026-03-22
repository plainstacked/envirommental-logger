const Discord = require('discord.js');
const { MessageEmbed } = require('discord.js');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const axios = require('axios');

const TOKEN = '';
const PREFIX = '.';
const RENAMER_BIN = './renamer';
const DUMPER_BIN = 'dumper.lua';
const WORK_DIR = '.';
const CONFIG_FILE = 'data.json';

let userConfigs = {};

// Load or create config file
function loadConfigs() {
    if (fs.existsSync(CONFIG_FILE)) {
        try {
            userConfigs = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
        } catch (e) {
            userConfigs = {};
        }
    }
}

// Save config file
function saveConfigs() {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(userConfigs, null, 2));
}

// Get user config
function getUserConfig(userId) {
    if (!userConfigs[userId]) {
        userConfigs[userId] = {
            hookOp: false,
        };
        saveConfigs();
    }
    return userConfigs[userId];
}

// Set user config
function setUserConfig(userId, key, value) {
    if (!userConfigs[userId]) {
        userConfigs[userId] = {};
    }
    userConfigs[userId][key] = value;
    saveConfigs();
}

const client = new Discord.Client({
    intents: 3276799,
});

async function downloadFile(attachment) {
    const response = await axios.get(attachment.url, { responseType: 'arraybuffer' });
    return Buffer.from(response.data);
}

async function downloadFromUrl(url) {
    const response = await axios.get(url, { responseType: 'arraybuffer' });
    return Buffer.from(response.data);
}

async function uploadToPastefy(content) {
    try {
        const response = await axios.post('https://pastefy.app/api/v2/paste', {
            content: content,
            visibility: 'PUBLIC',
        }, {
            headers: {
                'Content-Type': 'application/json',
            }
        });
        
        const pasteId = response.data.id || response.data.paste?.id || response.data.data?.id;
        if (!pasteId) {
            console.error('Pastefy response:', response.data);
            throw new Error('Could not get paste ID from response');
        }
        return `https://pastefy.app/${pasteId}/raw`;
    } catch (error) {
        console.error('Pastefy error:', error.response?.data || error.message);
        throw new Error(`Pastefy upload failed: ${error.response?.data?.message || error.message}`);
    }
}

async function renameFile(inputBuffer, filename) {
    const timestamp = Date.now();
    const inputPath = path.join(WORK_DIR, `input_${timestamp}_${filename}`);
    const outputPath = path.join(WORK_DIR, `output_${timestamp}_${filename}`);
    
    fs.writeFileSync(inputPath, inputBuffer);
    const startTime = process.hrtime.bigint();
    
    try {
        execSync(`${RENAMER_BIN} "${inputPath}" "${outputPath}"`, {
            stdio: 'pipe',
            timeout: 30000,
        });
    } catch (execError) {
        if (!fs.existsSync(outputPath)) {
            fs.unlinkSync(inputPath);
            throw new Error(execError.message);
        }
    }
    
    const endTime = process.hrtime.bigint();
    const elapsedMs = Number(endTime - startTime) / 1_000_000;
    const outputBuffer = fs.readFileSync(outputPath);
    
    fs.unlinkSync(inputPath);
    fs.unlinkSync(outputPath);
    
    return { buffer: outputBuffer, time: elapsedMs };
}

async function dumpFile(inputBuffer, filename, hookOp = false) {
    const timestamp = Date.now();
    const inputPath = path.join(WORK_DIR, `input_${timestamp}_${filename}`);
    const outputPath = path.join(WORK_DIR, `output_${timestamp}_${filename}`);
    
    fs.writeFileSync(inputPath, inputBuffer);
    const startTime = process.hrtime.bigint();
    
    try {
        const hookOpFlag = hookOp ? '--enablehookOp' : '';
        const cmd = `lua5.3 ${DUMPER_BIN} "${inputPath}" "${outputPath}" ${hookOpFlag}`.trim();
        execSync(cmd, {
            stdio: 'pipe',
            timeout: 60000,
        });
    } catch (execError) {
        if (!fs.existsSync(outputPath)) {
            fs.unlinkSync(inputPath);
            throw new Error(execError.message);
        }
    }
    
    const endTime = process.hrtime.bigint();
    const elapsedMs = Number(endTime - startTime) / 1_000_000;
    const outputBuffer = fs.readFileSync(outputPath);
    
    fs.unlinkSync(inputPath);
    fs.unlinkSync(outputPath);
    
    return { buffer: outputBuffer, time: elapsedMs };
}

function isValidFile(filename) {
    const ext = path.extname(filename).toLowerCase();
    return ['.lua', '.luau', '.txt'].includes(ext);
}

function isUrl(str) {
    try {
        new URL(str);
        return true;
    } catch (e) {
        return false;
    }
}

function cleanup() {
    const files = fs.readdirSync(WORK_DIR);
    for (const file of files) {
        if (file === 'renamer.c' || file === 'renamer' || file === 'bot.js' || file === 'dumper.lua' || file === CONFIG_FILE || file.startsWith('renamer')) {
            continue;
        }
        try {
            const fullPath = path.join(WORK_DIR, file);
            fs.unlinkSync(fullPath);
        } catch (e) {}
    }
}

client.on('ready', () => {
    console.log(`Logged in as ${client.user.tag}`);
    loadConfigs();
});

client.on('interactionCreate', async (interaction) => {
    if (!interaction.isButton()) return;
    
    try {
        if (interaction.customId.startsWith('hookop_enable_')) {
            const userId = interaction.customId.replace('hookop_enable_', '');
            if (interaction.user.id !== userId) {
                return interaction.reply({ content: 'You can only modify your own config', ephemeral: true });
            }
            
            setUserConfig(userId, 'hookOp', true);
            await interaction.reply({ content: 'hookOp enabled (green)', ephemeral: true });
        } else if (interaction.customId.startsWith('hookop_disable_')) {
            const userId = interaction.customId.replace('hookop_disable_', '');
            if (interaction.user.id !== userId) {
                return interaction.reply({ content: 'You can only modify your own config', ephemeral: true });
            }
            
            setUserConfig(userId, 'hookOp', false);
            await interaction.reply({ content: 'hookOp disabled (red)', ephemeral: true });
        }
    } catch (error) {
        console.error('Button error:', error);
        await interaction.reply({ content: `Error: ${error.message}`, ephemeral: true }).catch(() => {});
    }
});

client.on('messageCreate', async (message) => {
    if (message.author.bot) return;
    if (!message.content.startsWith(PREFIX)) return;
    
    const parts = message.content.slice(PREFIX.length).trim().split(/ +/);
    const command = parts[0].toLowerCase();
    const args = parts.slice(1).join(' ');
    const userId = message.author.id;
    
    if (command === 'upload') {
        try {
            let fileContent = null;
            
            if (message.reference) {
                const repliedMsg = await message.channel.messages.fetch(message.reference.messageId);
                const validFiles = repliedMsg.attachments.filter(att => isValidFile(att.name));
                
                if (validFiles.size === 0) {
                    return message.reply('No valid files in reply');
                }
                
                const attachment = validFiles.first();
                const fileBuffer = await downloadFile(attachment);
                fileContent = fileBuffer.toString('utf-8');
            } else if (message.attachments.size > 0) {
                const validFiles = message.attachments.filter(att => isValidFile(att.name));
                
                if (validFiles.size === 0) {
                    return message.reply('No valid files attached');
                }
                
                const attachment = validFiles.first();
                const fileBuffer = await downloadFile(attachment);
                fileContent = fileBuffer.toString('utf-8');
            } else {
                return message.reply('No file provided');
            }
            
            const pasteUrl = await uploadToPastefy(fileContent);
            
            await message.reply(`${pasteUrl}`);
        } catch (error) {
            await message.reply(`Error: ${error.message}`).catch(() => {});
        }
    }
    
    if (command === 'config') {
        try {
            const config = getUserConfig(userId);
            const hookOpStatus = config.hookOp ? 'enabled' : 'disabled';
            const hookOpColor = config.hookOp ? 3066993 : 15158332; // green or red
            
            const embed = new MessageEmbed()
                .setColor(hookOpColor)
                .setTitle('User Config')
                .addField('User ID', userId, true)
                .addField('hookOp', hookOpStatus, true)
                .setTimestamp();
            
            const buttons = {
                type: 1,
                components: [
                    {
                        type: 2,
                        label: 'Enable hookOp',
                        style: 3,
                        custom_id: `hookop_enable_${userId}`
                    },
                    {
                        type: 2,
                        label: 'Disable hookOp',
                        style: 4,
                        custom_id: `hookop_disable_${userId}`
                    }
                ]
            };
            
            await message.reply({ embeds: [embed], components: [buttons] });
        } catch (error) {
            await message.reply(`Error: ${error.message}`).catch(() => {});
        }
    }
    
    if (command === 'hookop') {
        try {
            const subcommand = args.toLowerCase();
            
            if (subcommand === 'enable') {
                setUserConfig(userId, 'hookOp', true);
                await message.reply('hookOp enabled (green)');
            } else if (subcommand === 'disable') {
                setUserConfig(userId, 'hookOp', false);
                await message.reply('hookOp disabled (red)');
            } else {
                await message.reply('Usage: .hookop enable/disable');
            }
        } catch (error) {
            await message.reply(`Error: ${error.message}`).catch(() => {});
        }
    }
    
    if (['l', 'env', 'log', 'envlog', 'dump'].includes(command)) {
        try {
            let fileBuffer = null;
            let filename = 'file.lua';
            
            if (args && isUrl(args)) {
                fileBuffer = await downloadFromUrl(args);
                filename = args.split('/').pop() || 'file.lua';
                if (filename === 'raw') {
                    filename = 'file.lua';
                }
            } else if (message.reference) {
                const repliedMsg = await message.channel.messages.fetch(message.reference.messageId);
                
                const urlMatch = repliedMsg.content.match(/(https?:\/\/[^\s]+)/);
                if (urlMatch && isUrl(urlMatch[0])) {
                    fileBuffer = await downloadFromUrl(urlMatch[0]);
                    filename = urlMatch[0].split('/').pop() || 'file.lua';
                    if (filename === 'raw') {
                        filename = 'file.lua';
                    }
                } else {
                    const validFiles = repliedMsg.attachments.filter(att => isValidFile(att.name));
                    
                    if (validFiles.size === 0) {
                        return message.reply('No valid files or URLs in reply');
                    }
                    
                    const attachment = validFiles.first();
                    fileBuffer = await downloadFile(attachment);
                    filename = attachment.name;
                }
            } else if (message.attachments.size > 0) {
                const validFiles = message.attachments.filter(att => isValidFile(att.name));
                
                if (validFiles.size === 0) {
                    return message.reply('No valid files attached');
                }
                
                const attachment = validFiles.first();
                fileBuffer = await downloadFile(attachment);
                filename = attachment.name;
            } else {
                return message.reply('No file provided');
            }
            
            const config = getUserConfig(userId);
            const result = await dumpFile(fileBuffer, filename, config.hookOp);
            const outputName = filename.replace(/\.(lua|luau|txt)$/, '_dumped.$1');
            
            await message.reply({
                content: `file dumped time taken: ${result.time.toFixed(4)} ms`,
                files: [{
                    attachment: result.buffer,
                    name: outputName,
                }],
            });
            
            cleanup();
        } catch (error) {
            cleanup();
            await message.reply(`Error: ${error.message}`).catch(() => {});
        }
    }
    
    if (command === 'r') {
        try {
            let fileBuffer = null;
            let filename = 'file.lua';
            
            if (args && isUrl(args)) {
                fileBuffer = await downloadFromUrl(args);
                filename = args.split('/').pop() || 'file.lua';
                if (filename === 'raw') {
                    filename = 'file.lua';
                }
            } else if (message.reference) {
                const repliedMsg = await message.channel.messages.fetch(message.reference.messageId);
                
                const urlMatch = repliedMsg.content.match(/(https?:\/\/[^\s]+)/);
                if (urlMatch && isUrl(urlMatch[0])) {
                    fileBuffer = await downloadFromUrl(urlMatch[0]);
                    filename = urlMatch[0].split('/').pop() || 'file.lua';
                    if (filename === 'raw') {
                        filename = 'file.lua';
                    }
                } else {
                    const validFiles = repliedMsg.attachments.filter(att => isValidFile(att.name));
                    
                    if (validFiles.size === 0) {
                        return message.reply('No valid files or URLs in reply');
                    }
                    
                    const attachment = validFiles.first();
                    fileBuffer = await downloadFile(attachment);
                    filename = attachment.name;
                }
            } else if (message.attachments.size > 0) {
                const validFiles = message.attachments.filter(att => isValidFile(att.name));
                
                if (validFiles.size === 0) {
                    return message.reply('No valid files attached');
                }
                
                const attachment = validFiles.first();
                fileBuffer = await downloadFile(attachment);
                filename = attachment.name;
            } else {
                return message.reply('No file provided');
            }
            
            const result = await renameFile(fileBuffer, filename);
            const outputName = filename.replace(/\.(lua|luau|txt)$/, '_renamed.$1');
            
            await message.reply({
                content: `file renamed time taken: ${result.time.toFixed(4)} ms`,
                files: [{
                    attachment: result.buffer,
                    name: outputName,
                }],
            });
            
            cleanup();
        } catch (error) {
            cleanup();
            await message.reply(`Error: ${error.message}`).catch(() => {});
        }
    }
});

client.on('error', error => console.error(error));
process.on('unhandledRejection', error => console.error(error));

client.login(TOKEN);

