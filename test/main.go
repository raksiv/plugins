package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/gorilla/mux"
)

type UploadRequest struct {
	Filename string `json:"filename"`
	Content  string `json:"content"`
}

type HealthResponse struct {
	Status    string `json:"status"`
	Timestamp string `json:"timestamp"`
	Version   string `json:"version"`
	Bucket    string `json:"bucket"`
}

type MessageResponse struct {
	Message  string `json:"message"`
	Filename string `json:"filename,omitempty"`
}

type FilesResponse struct {
	Files []string `json:"files"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Details string `json:"details,omitempty"`
}

var (
	s3Client   *s3.Client
	bucketName string
)

func init() {
	// Initialize AWS SDK
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatalf("Failed to load AWS config: %v", err)
	}

	s3Client = s3.NewFromConfig(cfg)

	// Get bucket name from environment (set by your Nitric platform)
	bucketName = os.Getenv("FILES_BUCKET_NAME")
	if bucketName == "" {
		// Fallback for local development
		stackId := os.Getenv("NITRIC_STACK_ID")
		if stackId == "" {
			stackId = "test-api-dev-local"
		}
		bucketName = fmt.Sprintf("%s-files", stackId)
	}
}

func enableCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
}

func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	enableCORS(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	version := os.Getenv("API_VERSION")
	if version == "" {
		version = "v1"
	}

	response := HealthResponse{
		Status:    "healthy",
		Timestamp: time.Now().Format(time.RFC3339),
		Version:   version,
		Bucket:    bucketName,
	}

	respondJSON(w, http.StatusOK, response)
}

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	var req UploadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error:   "Invalid JSON",
			Details: err.Error(),
		})
		return
	}

	if req.Filename == "" || req.Content == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error: "Missing filename or content",
		})
		return
	}

	// Decode base64 content
	content, err := base64.StdEncoding.DecodeString(req.Content)
	if err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error:   "Invalid base64 content",
			Details: err.Error(),
		})
		return
	}

	// Upload to S3
	_, err = s3Client.PutObject(context.TODO(), &s3.PutObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(req.Filename),
		Body:   bytes.NewReader(content),
	})

	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error:   "Upload failed",
			Details: err.Error(),
		})
		return
	}

	respondJSON(w, http.StatusOK, MessageResponse{
		Message:  "File uploaded successfully",
		Filename: req.Filename,
	})
}

func listFilesHandler(w http.ResponseWriter, r *http.Request) {
	result, err := s3Client.ListObjectsV2(context.TODO(), &s3.ListObjectsV2Input{
		Bucket: aws.String(bucketName),
	})

	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error:   "Failed to list files",
			Details: err.Error(),
		})
		return
	}

	var fileList []string
	for _, obj := range result.Contents {
		if obj.Key != nil {
			fileList = append(fileList, *obj.Key)
		}
	}

	respondJSON(w, http.StatusOK, FilesResponse{
		Files: fileList,
	})
}

func getFileHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	filename := vars["filename"]

	if filename == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error: "Missing filename parameter",
		})
		return
	}

	result, err := s3Client.GetObject(context.TODO(), &s3.GetObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(filename),
	})

	if err != nil {
		respondJSON(w, http.StatusNotFound, ErrorResponse{
			Error:   "File not found",
			Details: err.Error(),
		})
		return
	}
	defer result.Body.Close()

	// Read the file content
	content, err := io.ReadAll(result.Body)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error:   "Failed to read file",
			Details: err.Error(),
		})
		return
	}

	enableCORS(w)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%s", filename))
	w.Write(content)
}

func deleteFileHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	filename := vars["filename"]

	if filename == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error: "Missing filename parameter",
		})
		return
	}

	_, err := s3Client.DeleteObject(context.TODO(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(filename),
	})

	if err != nil {
		if strings.Contains(err.Error(), "NoSuchKey") {
			respondJSON(w, http.StatusNotFound, ErrorResponse{
				Error: "File not found",
			})
		} else {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error:   "Delete failed",
				Details: err.Error(),
			})
		}
		return
	}

	respondJSON(w, http.StatusOK, MessageResponse{
		Message:  "File deleted successfully",
		Filename: filename,
	})
}

func optionsHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(w)
	w.WriteHeader(http.StatusOK)
}

func main() {
	// Create router
	r := mux.NewRouter()

	// API routes
	api := r.PathPrefix("/api").Subrouter()
	api.HandleFunc("/health", healthHandler).Methods("GET")
	api.HandleFunc("/upload", uploadHandler).Methods("POST")
	api.HandleFunc("/files", listFilesHandler).Methods("GET")
	api.HandleFunc("/files/{filename}", getFileHandler).Methods("GET")
	api.HandleFunc("/files/{filename}", deleteFileHandler).Methods("DELETE")

	// Handle preflight CORS requests
	r.Methods("OPTIONS").HandlerFunc(optionsHandler)

	// Get port from environment
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	fmt.Printf("API server starting on port %s...\n", port)
	fmt.Printf("Environment: %s\n", os.Getenv("NODE_ENV"))
	fmt.Printf("API Version: %s\n", os.Getenv("API_VERSION"))
	fmt.Printf("S3 Bucket: %s\n", bucketName)

	log.Fatal(http.ListenAndServe(":"+port, r))
}
