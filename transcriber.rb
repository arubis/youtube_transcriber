#!/usr/bin/env ruby

require 'thor'
require 'terrapin'
require 'openai'
require 'fileutils'
require 'streamio-ffmpeg'

FFMPEG.ffmpeg_binary = `which ffmpeg`.strip

class TranscriptSummarizer < Thor
  desc "process URL", "Download, transcribe, and summarize a YouTube video"
  option :output, default: 'output', desc: 'Output directory'

  def process(url)
    setup_output_directory(options[:output])
    video_path = download_video(url, options[:output])
    transcript = transcribe_audio(video_path)
    save_transcript(transcript, options[:output])
    summary = generate_summary(transcript)
    save_summary(summary, options[:output])
  end

  private

  def setup_output_directory(output_dir)
    FileUtils.mkdir_p(output_dir)
  end

  def download_video(url, output_dir)
    puts "Downloading video..."
    video_path = File.join(output_dir, 'video.mp3')
    Terrapin::CommandLine.new("yt-dlp", "-x --audio-format mp3 -o :output :url").run(output: video_path, url: url)
    video_path
  end

  def transcribe_audio(audio_path)
    puts "Transcribing audio..."
    client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
    movie = FFMPEG::Movie.new(audio_path)
    (0..movie.duration).step(600).map do |start_time|
      end_time = [start_time + 600, movie.duration].min
      chunk_path = "#{audio_path}_chunk_#{start_time}_#{end_time}.mp3"
      movie.transcode(chunk_path, { seek_time: start_time, duration: end_time - start_time })
      response = client.audio.transcribe(parameters: { model: "whisper-1", file: File.open(chunk_path, "rb") })
      FileUtils.rm(chunk_path)
      response['text']
    end.join("\n\n")
  end

  def save_transcript(transcript, output_dir)
    File.write(File.join(output_dir, 'transcript.txt'), transcript)
  end

  def generate_summary(transcript)
    puts "Generating summary..."
    summarize_with_gpt4(transcript)
  rescue => e
    puts "Error generating summary: #{e.message}"
    transcript
  end

  def summarize_with_gpt4(transcript)
    client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
    prompt = "Listen to the provided presentation or talk and analyze the content. Identify the key speakers and their roles. Summarize the major points of discussion, key takeaways, and any decisions made. Highlight important details, such as questions raised and responses given. Organize the information into a structured format with clear headings and bullet points for easy readability. Ensure the summary captures the essence of the presentation, providing a comprehensive overview that includes action items and follow-up tasks where applicable. Here's the transcript:\n\n"
    
    transcript.scan(/.{1,14000}/m).map.with_index do |chunk, index|
      puts "Summarizing chunk #{index + 1}..."
      response = client.chat(parameters: {
        model: "gpt-4",
        messages: [
          { role: "system", content: "You are an AI assistant that summarizes transcripts." },
          { role: "user", content: prompt + chunk }
        ],
        max_tokens: 1000
      })
      response.dig("choices", 0, "message", "content") || raise("Unexpected response format")
    end.join("\n\n")
  end

  def save_summary(summary, output_dir)
    File.write(File.join(output_dir, 'summary.txt'), summary)
  end
end

TranscriptSummarizer.start(ARGV)
